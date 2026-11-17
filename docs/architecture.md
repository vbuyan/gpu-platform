# Architecture

One workstation, two teams, one GPU. The host keeps doing its production work (ComfyUI and Ollama
behind a GPU queue, Blender renders, video pipelines). The cluster lives next to it under hard
limits and treats the host's existing services as the source of truth for the GPU.

## The host and the cluster

```mermaid
flowchart TB
  subgraph gh[GitHub: vbuyan/gpu-platform]
    repo[(main, protected:<br/>4 required checks)]
    ci[Actions: lint, tests,<br/>kubeconform, kind, terraform]
    ghcr[(GHCR: gpu-queue-exporter)]
  end

  subgraph host[Workstation: Ubuntu 24.04, 16 CPU, 31 GiB RAM, RTX 3090]
    subgraph studio[Studio workloads: unchanged]
      comfy[ComfyUI / Ollama<br/>behind a GPU gate]
      jobs[gpu run jobs:<br/>renders, clips, LoRA]
    end
    queue{{GPU dispatcher<br/>/run/gpu/ochered.sock}}
    guard[gpu-dostup: device ACL<br/>for the current holder only]
    gpu[(RTX 3090)]

    subgraph k8s[kubepods.slice: capped at 6.5 GiB, yields memory first]
      argo[Argo CD]
      mon[Prometheus, Alertmanager,<br/>Grafana, node-exporter<br/>+ GPU-queue exporter]
      gpujob[GPU pod: runtime class gpu-queue<br/>entrypoint /opt/gpu-queue/turn]
    end
  end

  tg[Telegram]

  repo -- sync --> argo
  argo -- applies --> mon
  argo -- applies --> gpujob
  ci -- builds --> ghcr
  comfy --> queue
  jobs --> queue
  gpujob -- joins as kube-gpu --> queue
  queue --> guard --> gpu
  mon -. reads files, never NVML .-> queue
  mon --> tg
```

## Layers

| Layer | What | Why this way |
|---|---|---|
| Install | kubeadm 1.37, containerd 2.2, Cilium 1.20 (kube-proxy kept), dead man's switch | Real control plane like at work and on the CKA; a remote host must heal itself if an install cuts access (ADR-001, 005, 006) |
| Memory | `systemReserved: 24Gi` caps every pod, the control plane included, at ~6.5 GiB; eviction at 4 / 2 GiB available; oomd watches the cluster at 20 % pressure vs 50 % for the studio | The cluster can never take the host down, and under pressure it is the first to go (ADR-002, 011) |
| GitOps | Argo CD app of apps from `gitops/`; Argo CD manages its own upgrades | One `kubectl apply` by hand, everything else from Git (ADR-008) |
| GPU | No device plugin. CDI devices + RuntimeClass `gpu-queue`; the pod's entrypoint joins the host queue and keeps the connection open while it runs | Kubernetes cannot see the studio's GPU use; the existing queue is the right arbiter (ADR-009) |
| Policy | ValidatingAdmissionPolicy in CEL: GPU only in `jobs`, one container, wrapper first, uid 2950, runtime class required; Pod Security `restricted` in `jobs` | A GPU pod that skips the queue cannot be created; 10 bypass cases are tested in CI |
| Network | Cilium; NetworkPolicy keeps `jobs` off the LAN, the tailnet and other namespaces; tagged host-firewall exceptions | The host must stay invisible to the home network (ADR-007) |
| Observability | kube-prometheus-stack, a textfile exporter for the GPU and the queue, 12 alert rules tuned to this host, Telegram | DCGM would open NVML as root and break the queue's device guard (ADR-010) |
| CI/CD | shellcheck, yamllint, pytest, kubeconform on rendered charts, admission tests on kind, Terraform checks; image built, scanned with Trivy, pushed to GHCR | What runs in production is what was tested |
| IaC | Terraform for the Argo CD bootstrap and the GitHub repository; state in the cluster | The two things Argo CD cannot manage for itself (ADR-012) |

## A GPU job, step by step

```mermaid
sequenceDiagram
  participant U as kubectl apply (Job)
  participant API as API server + admission policy
  participant K as kubelet / containerd
  participant R as nvidia-container-runtime (CDI)
  participant T as /opt/gpu-queue/turn
  participant Q as GPU dispatcher (host)
  participant S as Studio job on the GPU

  U->>API: pod with runtimeClassName gpu-queue + cdi.k8s.io/gpu
  API-->>U: admitted (namespace, wrapper, uid, runtime class all match)
  K->>R: create container, pod annotations passed through
  R->>T: devices, driver libs, /run/gpu socket and wrapper injected
  T->>Q: "wait k8s gpu-smoke"
  Q-->>T: "ahead of you: 0" (studio render holds the card)
  S-->>Q: render finishes, connection closes
  Q-->>T: "yours"
  T->>T: wait for free VRAM, exec the job with the queue socket on fd 9
  Note over T: fp16 matmul: 66 TFLOPS, 520 MiB VRAM
  T-->>Q: process exits, kernel closes fd 9
  Q-->>S: next host job gets the card 2 s later
```

## Failure modes and what happens

| Failure | Effect | Handled by |
|---|---|---|
| Host short of RAM | Cluster pods evicted at 4 / 2 GiB; oomd kills cluster before studio | ADR-011, `StationMemoryLow` alert |
| Root disk nearly full | Pods evicted under 20 GiB free; host alerts under 5 % / 40 GiB | ADR-011, postmortem 2026-11-15 |
| GPU dispatcher restarts | Waiting GPU pods exit with a clear message; the Job's backoff decides | `turn`, tests in `tests/test_turn.py` |
| Device guard stops updating | GPU metrics go stale | `GPUSnapshotStale` alert |
| Someone edits the cluster by hand | Argo CD reverts it | `selfHeal: true` |
| Git and cluster drift | `ArgoAppNotHealthy` after 15 min | Alert |
| Bad install over the remote link | Auto-rollback in 20 or 45 min unless confirmed | Dead man's switch, postmortem 2026-11-14 |

## Known limits

- One node. High availability is out of scope; the goal is safe co-existence with the host.
- Kubernetes does not count or queue GPUs itself; a GPU pod holds its CPU and memory requests while
  it waits in the host queue.
- The exporter image is built and scanned, but the cluster still runs the script from a ConfigMap on
  the public Python image; moving it to the GHCR image needs a pull secret or a public package.
