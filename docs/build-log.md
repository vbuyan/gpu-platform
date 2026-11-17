# Build log

What each stage delivered, with the numbers measured at the time. Decisions are in
[decisions.md](decisions.md), incidents in [postmortems/](postmortems/).

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

## Stage 6 result (2026-11-16)

- `ci` on every push and pull request, green on the first run:
  - shellcheck on every installer and helper, yamllint on all YAML;
  - 10 unit tests: the GPU-queue exporter on fixture files, and the queue wrapper `turn` against a fake
    dispatcher (waits, keeps the connection across exec, releases on exit, reports refusals);
  - every chart Argo CD deploys rendered with this repo's values and validated by kubeconform (163 objects);
  - a throwaway kind cluster with the platform layer applied: 12 admission cases, 1 correct GPU pod
    admitted, 1 ordinary pod admitted, 10 bypass attempts denied.
- `image` builds the exporter, scans it with Trivy and pushes it to `ghcr.io/vbuyan/gpu-queue-exporter`.
  The first scan blocked the image: the Python base lagged behind Debian security fixes (4 fixable HIGH
  CVEs in apt and zlib). The Dockerfile now applies the updates and drops pip.
- Third-party actions are pinned; the scanner action is pinned by commit SHA because its tags were
  re-pointed in a 2026 supply-chain incident.
- The new checks found 14 shellcheck issues in code that already ran in production (mostly quoting); all fixed.

## Stage 7 result (2026-11-16)

- `terraform/cluster` adopted the running Argo CD release and the root Application with `import`
  blocks: 2 imported, 0 created, 0 destroyed, one no-op `helm upgrade`. `plan -detailed-exitcode` is 0.
- `terraform/github` adopted the repository and added a protected `main`: required checks
  `lint-and-test`, `manifests`, `admission-policy`, `terraform`; linear history; no force pushes or
  deletion; vulnerability alerts on. `plan -detailed-exitcode` is 0.
- State for both lives in the cluster (`kubernetes` backend, Secrets in `kube-system`).
- CI got a fourth job: `terraform fmt -check` and `terraform validate` for both modules.
- Side finding while adopting: kubelet's default disk threshold (5 %, ~90 GiB here) had evicted 209 pods
  in one night on a disk the studio keeps 95 % full; now an absolute 20 GiB (ADR-011).

## Stage 8 result (2026-11-16)

- [architecture.md](architecture.md): layers, a GPU job step by step, failure modes, known limits.
- Three postmortems with timelines rebuilt from logs and Prometheus history.
- The disk-pressure postmortem produced two new alerts: `KubeNodeUnderPressure` and `PodsEvicted`.
- README rewritten for a first-time reader; per-stage results moved here.

## Stage 4 result (2026-11-16)

- CronJob `subtitles` (01:15 station time) plus `bin/subtitles add|now|status`. First run on two
  published short videos: 24 s and 27 s of speech transcribed in about 1 s each
  (16x and 36x realtime), 9 and 13 subtitle lines, numbers such as "1,700" and "50 to 60" correct.
- The pod joined the shared GPU queue as a background job, held the card for 22 s and gave it back.
- It also waited 7886 s first: a host render had its turn but sat waiting for VRAM held by an idle
  ComfyUI whose pending jobs needed the same turn, a deadlock on the host side. The pod waited
  patiently and never jumped the queue; the station's operators cleared the deadlock by hand.
- The image needed four CI runs: PEP 668 in the PyTorch base, then Trivy blocked it three times on
  critical CVEs shipped with the base (Pillow, certifi and uv CA stores, pip's vendored certifi).
  Each was fixed in the Dockerfile; the gate was never loosened.

