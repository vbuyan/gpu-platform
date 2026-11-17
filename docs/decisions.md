# Decisions

## ADR-001: kubeadm, not k3s

**Context.** Lightweight distributions (k3s, k0s) would install faster and use less memory.
**Decision.** Use upstream kubeadm with containerd.
**Why.** The goal includes operating Kubernetes the way most employers and the CKA exam do:
static-pod control plane, etcd, certificates, kubelet configuration, upgrades with kubeadm.
The memory cost of the control plane fits inside the cluster budget (ADR-002).

## ADR-002: one memory cap for the whole cluster

**Context.** Most of the host's RAM is usually in use by ComfyUI, Ollama and
batch jobs. Two multi-hour freezes in October were caused by RAM exhaustion.
**Decision.** `systemReserved: 24Gi` with `enforceNodeAllocatable: [pods]`. The kubelet caps
`kubepods.slice` at host memory minus the reservation, and every container, including the static control-plane pods,
lives under it.
**Consequence.** The cluster can be OOM-killed inside its own budget but cannot take the host down.
Workloads must declare requests and limits that fit.

## ADR-003: on-demand cluster

**Context.** The cluster is a platform under construction on a production machine.
**Decision.** containerd and kubelet are disabled at boot. `sudo k8s on` starts them and waits for
the API server; `sudo k8s off` stops every pod sandbox first, then the services, so no container
keeps running behind a stopped containerd.

## ADR-004: keep host swap, pods never swap

**Context.** The host relies on swap plus systemd-oomd; kubeadm expects swap off.
**Decision.** `failSwapOn: false` and `swapBehavior: NoSwap`: the node keeps swap, pod memory is
never swapped, so limits stay predictable.

## ADR-005: dead man's switch on install

**Context.** The host is reached only over Tailscale. A CNI or iptables mistake can cut access,
and there is no console.
**Decision.** The installer arms a systemd timer before touching anything (45 min for the install,
then 20 min after it). Unless the operator runs `--confirm` from a working SSH session, the timer
runs `--rollback`, which resets kubeadm, removes Cilium interfaces and KUBE/CILIUM iptables rules,
and purges the packages.

## ADR-006: Cilium with kube-proxy kept

**Decision.** Cilium as the CNI (eBPF, network policy, Hubble later), but `kubeProxyReplacement: false`.
**Why.** Replacing kube-proxy changes host-level service routing; on a remote production host the
smaller blast radius is worth more than the feature.

## ADR-007: narrow firewall exceptions instead of opening the host

**Context.** The host firewall (ufw) forbids outbound traffic to private ranges on the LAN port, so
the workstation cannot reach devices on the home network. The first install got a healthy control
plane, but Cilium crash-looped: `dial tcp 10.96.0.1:443: i/o timeout`. The Service IP is routed to
the LAN port before kube-proxy rewrites it to the node's own address (`<node-ip>:6443`); the packet
then matched `deny out on eno1 to 192.168.0.0/16`. Rule counters confirmed it: +3 drops per attempt.
**Decision.** Keep the isolation and add tagged exceptions: node-to-itself, Service and pod ranges
on the LAN port, pods to the host, pods to the internet, and explicit denies from pods to the home
LAN and the tailnet. `--rollback` deletes exactly the rules tagged `gpu-platform`.

## ADR-008: app of apps, Argo CD manages itself

**Decision.** Only `gitops/root-app.yaml` is applied by hand. It points at `gitops/apps/`, where each
file is an Application: Argo CD itself (Helm chart, values from this repo) and `platform`
(namespaces, quotas, limit ranges, network policy). Upgrading Argo CD is a one-line commit.
**Budget.** Argo CD requests 560 MiB and is limited to 1.75 GiB; dex (SSO) and notifications are off.
The UI is reached through `kubectl port-forward` over SSH, so it is never exposed on the network.
**Guard rails.** Workload namespaces get a ResourceQuota and a LimitRange, so a container without
limits still gets one; `jobs` may reach DNS and the internet but not private ranges or the tailnet.
Self-management uses `prune: false`, so a bad commit cannot delete Argo CD.

## ADR-009: the GPU stays outside the scheduler; pods take turns in the existing queue

**Context.** One consumer GPU is shared by two teams through a host dispatcher (`gpu run`): one owner at
a time, the device files are opened (ACL) only for the current owner, a janitor unloads idle models.
The NVIDIA device plugin would advertise `nvidia.com/gpu: 1` and hand the card to a pod whenever
Kubernetes thinks it is free. Kubernetes cannot see the host workloads, so it would always think so.
It also runs NVML as root, which resets the device permissions the queue relies on.
**Decision.** No device plugin. The GPU is described with CDI (`nvidia-ctk cdi generate`, run as an
unprivileged user in the GPU group) and a second CDI device mounts the queue socket and a wrapper,
`/opt/gpu-queue/turn`. A GPU pod asks for both with one annotation. The wrapper joins the same queue
as `gpu run`, waits for its turn and for free VRAM, then execs the job and keeps the queue
connection open: when the process ends or the pod is killed, the card passes to the next waiter.
In the queue the cluster appears as its own user, `kube-gpu` (uid 2950), next to the two teams.
**Enforcement.** A ValidatingAdmissionPolicy (CEL, no webhook) allows the CDI annotation and the runtime class only in
namespace `jobs`, only with exactly one container whose command starts with the wrapper, and only
as uid 2950. `jobs` enforces Pod Security `restricted`: no root, no capabilities, no host paths.
Tested with server-side dry runs: a correct pod is admitted; ten bypass attempts are denied.
The wrapper was tested against a private copy of the dispatcher: the second job waited for the
first and got the card the moment the first process exited.
**First attempt and the fix.** The first test pod was admitted but failed to start: `exec
/opt/gpu-queue/turn: no such file or directory`. containerd injects CDI devices named in container
annotations, and kubelet does not copy pod annotations there. The fix is the usual NVIDIA pattern: a
RuntimeClass `gpu-queue` whose containerd handler passes `cdi.k8s.io/*` pod annotations into the OCI
spec and runs `nvidia-container-runtime` in CDI mode, which injects the devices. Pods of every other
class keep plain runc. The toolkit package also enabled `nvidia-cdi-refresh`, which runs `nvidia-smi`
as root at boot and resets the device permissions; the installer masks it.
**Trade-off.** Kubernetes cannot count GPUs or queue GPU pods itself; a waiting pod holds its CPU and
memory requests while it waits. On one shared card the existing queue is the better arbiter, and the
studio sees the cluster as one more polite participant instead of a competitor.

## ADR-010: monitoring without touching the GPU

**Decision.** kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter,
kube-state-metrics) managed by Argo CD, with volumes from local-path-provisioner. GPU metrics do not
come from DCGM or the NVIDIA exporter: both open NVML as root, which resets the device permissions the
queue relies on (ADR-009), and they would use the card outside the queue. A small sidecar of
node-exporter (`gitops/monitoring/extras/gpu_queue_exporter.py`) turns what the queue services already
publish into textfile metrics: the `nvidia-smi` snapshot that the device guard takes without root,
the waiting list, the current holder and the job log (jobs, failures, GPU hours and longest wait per
owner over 24 h). It mounts `/run/gpu` and `/srv` read-only as directories, because the dispatcher
replaces its state files atomically and a single-file bind mount would keep the old inode.
**Alerts** are tuned to this host's history rather than generic defaults: available RAM under 2 GiB and
swap over 20 GiB (where the October freezes began), root disk under 5 % or 40 GiB, GPU over 85 C,
a stale GPU snapshot (the device guard is down), a job waiting over an hour, a holder idle for 4 h,
the cluster near its memory cap, an Argo CD application out of sync. kubeadm binds etcd, the
scheduler, the controller manager and kube-proxy metrics to localhost, so those scrapers and their
rules are off instead of reporting "down" forever. `Watchdog` goes to a null receiver.
**Secrets.** The Telegram token and chat id stay out of Git. `bin/make-alert-secret` reads the station's
existing bot config (root only) and creates the Alertmanager config Secret from
`gitops/monitoring/alertmanager.example.yaml`.
**Budget.** Explicit requests ~0.9 GiB, limits ~2.6 GiB; the `monitoring` namespace quota is 1.5 / 4 GiB.
The first deploy OOM-killed Grafana and its sidecars at 256 / 96 MiB; they now get 512 / 192 MiB,
and Grafana uses the Recreate strategy because its volume is ReadWriteOnce.

## ADR-011: always on, first to yield (supersedes ADR-003 for day-to-day use)

**Context.** Monitoring and alerts are only useful if the cluster runs all the time; on-demand meant
silence after every reboot. Measured with the full stack running: the cluster stays well under its cap, the host kept
a comfortable margin of available memory over two hours of 3D rendering, and
systemd-oomd killed nothing in the previous week. The risk is the rare peak when big models load
while a render runs: the October freezes began at about 2 GiB available.
**Decision.** containerd and kubelet start at boot, and the cluster gives memory back first:
- kubelet eviction on host `memory.available`: soft 4 GiB for 30 s, hard 2 GiB. Evicted pods stay
  away while the node has the MemoryPressure taint; only the static control plane (~1 GiB) remains.
- systemd-oomd watches `kubepods.slice` with a 20 % memory-pressure limit, stricter than the 50 %
  on `system.slice`, so under real pressure it kills cluster pods before studio jobs.
- The cgroup cap (ADR-002) still bounds the cluster from above.
**Disk, found the first night.** The default `nodefs.available: 5%` is a lot of space on a large disk,
and the studio keeps the disk just above that line: kubelet evicted every pod three times in one night (209
evicted pods, all of them on disk pressure, none on memory). The floor is now an absolute value sized for the pods.
**Review.** The `StationMemoryLow` alert and the "Memory: host available vs cluster" panel show whether
this costs the studio anything. If available memory often drops under 3 GiB with the cluster running,
`install-always-on.sh --rollback` returns to on-demand.

## ADR-012: Terraform for what Git cannot hold by itself

**Context.** Argo CD already applies everything inside the cluster from Git. Two things sit outside
that loop: the bootstrap (installing Argo CD and the root Application, which no Argo CD can do for
itself) and the GitHub repository (settings, topics, security features, branch protection).
**Decision.** Two small root modules, both adopting what already existed with `import` blocks instead
of recreating it:
- `terraform/cluster`: `helm_release.argocd` (bootstrap only: versions and values are ignored after
  the first install because Argo CD upgrades itself, ADR-008) and `kubernetes_manifest.root`.
- `terraform/github`: the repository and a protected `main` that requires the CI jobs
  `lint-and-test`, `manifests`, `admission-policy` and `terraform`; linear history, no force pushes.
  The owner can still push a hotfix (`enforce_admins = false`).
**State** lives in the cluster it describes (backend `kubernetes`, Secrets in `kube-system`, locking
through a Lease): no cloud bucket, nothing on a laptop. The GitHub token comes from the environment
and never enters the state.
**Adoption.** `import` brought the running Argo CD under Terraform with one no-op `helm upgrade` (the
imported release has no chart repository in state; ignoring `repository` makes the provider fail to
locate the chart). After apply, `terraform plan -detailed-exitcode` returns 0.
**CI** runs `terraform fmt -check` and `terraform validate` for both modules on every push.

## ADR-013: the first real workload is nightly subtitles

**Context.** Stage 4 needed work the studio actually wants, not a demo, and nothing the host already
does. The studio publishes English videos; video platforms use captions for search and automatic
dubbing, and the host had no captioning pipeline.
**Decision.** A CronJob in `jobs` at 01:15 station time: every audio or video file in
`~/k8s-media/inbox` without a matching `.srt` gets subtitles from Whisper large-v3-turbo, written to
`~/k8s-media/outbox` as `.srt` plus `.txt`. It joins the GPU queue as a background job, so at night
the studio goes first. Audio is decoded with PyAV, so the image needs no ffmpeg binary.
**Data.** Two static local PersistentVolumes (media folders, and the model weights copied once from the
host's Hugging Face cache, mounted read-only). Pods only see PVCs, so `jobs` keeps Pod Security
`restricted`. The image (PyTorch CUDA base + transformers) is built, scanned and pushed by CI; it
blocks on critical CVEs only, because the CUDA/PyTorch base always carries some high ones.
**Known weakness.** Whisper drops or mangles numbers (seen in earlier runs on this host); the `.txt` makes them
quick to check. When the script is known, forced alignment of the script is the better tool.
**Budget.** The container limit is 3 GiB (weights pass through RAM on load); the `jobs` LimitRange
maximum went from 2 to 3 GiB and its quota from 3 to 4 GiB.
