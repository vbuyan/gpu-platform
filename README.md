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
| 2 | GitOps: Argo CD syncs everything from this repo | ready, waits for the public repo |
| 3 | GPU: NVIDIA container toolkit + device plugin, GPU pods gated by the shared queue | planned |
| 4 | Workloads: ComfyUI and Ollama as Helm charts, a render Job pipeline | planned |
| 5 | Observability: Prometheus, Grafana, DCGM GPU metrics, alerts, SLOs | planned |
| 6 | CI: GitHub Actions builds, scans and publishes images to GHCR | planned |
| 7 | Terraform: the same stack declared as code, plus an optional one-day cloud replica | planned |
| 8 | Write-ups: architecture, decisions, two incident postmortems with numbers | planned |

## Layout

```
bootstrap/   host install: install-kubernetes.sh, kubeadm-config.yaml, cilium-values.yaml
bin/k8s      start / stop / status of the on-demand cluster
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
