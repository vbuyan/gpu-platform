# gpu-platform

Kubernetes platform for generative-media workloads on a shared GPU workstation.

The workstation already runs a production setup: one RTX 3090 shared by two teams through a
custom GPU scheduler, ComfyUI and Ollama servers, video pipelines.
This project moves that platform onto standard tooling (kubeadm, Helm, GitOps, Prometheus)
without disrupting the people who depend on the machine.

## Constraints

| Constraint | How the platform handles it |
|---|---|
| RAM is the bottleneck (31 GiB, often 25 GiB used) | The whole cluster lives in one cgroup capped at ~6.5 GiB |
| Two teams share the host | The cluster runs on demand: `sudo k8s on` / `sudo k8s off` |
| One GPU shared through an existing queue | GPU pods will acquire the card through the same queue, never around it |
| Remote host, reached only over Tailscale | Install arms a dead man's switch that rolls everything back unless confirmed |
| Host swap must stay on | kubelet `failSwapOn: false`, `swapBehavior: NoSwap` |
| Host firewall blocks the home LAN | Tagged ufw exceptions for cluster ranges; pods still cannot reach the LAN (ADR-007) |

## Roadmap

| Stage | What | Status |
|---|---|---|
| 1 | kubeadm cluster: containerd, Cilium, memory cap, on-demand control, auto-rollback | done (2026-11-14) |
| 2 | GitOps: Argo CD syncs everything from this repo | done (2026-11-15) |
| 3 | GPU: CDI + the shared queue, admission policy instead of a device plugin (ADR-009) | done (2026-11-15) |
| 4 | Workloads: ComfyUI and Ollama as Helm charts, a render Job pipeline | planned |
| 5 | Observability: Prometheus, Grafana, GPU-queue metrics without NVML, Telegram alerts (ADR-010) | done (2026-11-15) |
| 6 | CI: GitHub Actions builds, scans and publishes images to GHCR | planned |
| 7 | Terraform: the same stack declared as code, plus an optional one-day cloud replica | planned |
| 8 | Write-ups: architecture, decisions, two incident postmortems with numbers | planned |

## Layout

```
bootstrap/   host install: install-kubernetes.sh, kubeadm-config.yaml, cilium-values.yaml
bin/k8s      start / stop / status of the on-demand cluster
gpu-queue/   turn: entrypoint of GPU pods, waits for the station GPU queue
examples/    gpu-smoke-job.yaml: fp16 matmul benchmark through the queue
gitops/      Argo CD app of apps: root-app.yaml -> apps/ -> platform/ (namespaces, quotas, network policy)
docs/        decisions (ADRs), architecture, postmortems
```

## Install

```bash
sudo bash bootstrap/install-kubernetes.sh            # ~10 min, arms a 20-min auto-rollback
sudo bash bootstrap/install-kubernetes.sh --confirm  # after checking SSH still works
sudo bash bootstrap/install-kubernetes.sh --rollback # remove everything
```

## Stage 1 result (2026-11-14)

- Kubernetes v1.37.2 (kubeadm), containerd 2.2.1, Cilium 1.20.4, Helm v4.3.2; node `Ready`, 10 system pods running.
- Memory: the whole cluster idles at **0.77 GiB** inside a **6.5 GiB** cgroup cap.
- Install took about 2 minutes on the third attempt. The first two failed and were rolled back automatically:
  1. a half-configured NVIDIA kernel-module package (kernel headers missing after an unattended upgrade)
     broke `apt-get`; the installer now refuses to start on a dirty package database;
  2. the host firewall dropped Service traffic to the API server, so Cilium crash-looped
     (`10.96.0.1:443: i/o timeout`); fixed with tagged firewall exceptions, see ADR-007.

## Stage 2 result (2026-11-15)

- Argo CD v3.6.1 installed with `bootstrap/install-argocd.sh`; after that the only manual step was
  `kubectl apply -f gitops/root-app.yaml`. Applications `root`, `argocd` and `platform`: Synced, Healthy.
- Argo CD now manages its own Helm release from `gitops/apps/argocd.yaml`.
- `platform` created namespaces `jobs` and `monitoring` with quotas and default limits. A pod started
  without resources got `requests 50m/64Mi, limit 256Mi` from the LimitRange.
- Network policy, tested from a pod in `jobs`: internet reachable, home LAN router blocked,
  Argo CD service blocked.
- Memory with Argo CD: 1.41 GiB used by processes (plus 1.05 GiB reclaimable page cache) under the 6.5 GiB cap.

## Stage 3 result (2026-11-15)

- GPU pods use `runtimeClassName: gpu-queue` and one CDI annotation; no device plugin (ADR-009).
- Admission policy `gpu-through-queue`: a correct GPU pod is admitted, 10 of 10 bypass attempts are
  denied (wrong namespace, no wrapper, root or another user, GPU without the queue, extra containers,
  missing runtime class).
- Live test, `examples/gpu-smoke-job.yaml`, on the production queue while a Blender render held the card:
  - the pod joined the queue as `kube-gpu` and waited **927 s**, behind the render and ahead of the
    next host job, exactly like any `gpu run`;
  - it got the card with 23.6 GiB VRAM free, ran an fp16 matmul benchmark on the RTX 3090:
    **66.0 TFLOPS**, peak 520 MiB VRAM;
  - the dispatcher log shows the card released 2 s later, the moment the process exited, and the
    next host job started on time. Device permissions stayed with the queue throughout.

## Stage 5 result (2026-11-15)

- Argo CD applications `storage` (local-path-provisioner), `monitoring` (kube-prometheus-stack) and
  `monitoring-extras` (GPU-queue exporter, station alert rules, dashboard): all Synced, Healthy.
- 16 of 16 scrape targets up. Prometheus keeps 30 days (max 8 GB) on a local volume.
- GPU and queue metrics without NVML (ADR-010). From the first day: jobs, GPU time, failures
  and longest wait per owner over the last 24 h.
- 10 station alert rules; a test alert reached Telegram through the station's existing bot, and the
  token never touched Git.
- Two problems on the first deploy, both fixed in Git: Grafana and its sidecars were OOM-killed at
  256 / 96 MiB (now 512 / 192 MiB, Recreate strategy), and the exporter's 24 h window was 8 h off because
  the container ran in UTC while the queue logs local time (now mounts the host's /etc/localtime).
- Whole cluster with monitoring: ~2.8 GiB of process memory under the 6.5 GiB cap.
