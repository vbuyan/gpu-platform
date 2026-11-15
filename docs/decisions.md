# Decisions

## ADR-001: kubeadm, not k3s

**Context.** Lightweight distributions (k3s, k0s) would install faster and use less memory.
**Decision.** Use upstream kubeadm with containerd.
**Why.** The goal includes operating Kubernetes the way most employers and the CKA exam do:
static-pod control plane, etcd, certificates, kubelet configuration, upgrades with kubeadm.
The memory cost (about 1.5 to 2 GiB for the control plane) fits inside the cluster budget (ADR-002).

## ADR-002: one memory cap for the whole cluster

**Context.** The host has 31 GiB of RAM, usually 20 to 25 GiB in use by ComfyUI, Ollama and
batch jobs. Two multi-hour freezes in October were caused by RAM exhaustion.
**Decision.** `systemReserved: 24Gi` with `enforceNodeAllocatable: [pods]`. The kubelet caps
`kubepods.slice` at roughly 6.5 GiB, and every container, including the static control-plane pods,
lives under it.
**Consequence.** The cluster can be OOM-killed inside its own budget but cannot take the host down.
Workloads must declare requests and limits that fit.

## ADR-003: on-demand cluster

**Context.** The cluster is a platform under construction on a production machine.
**Decision.** containerd and kubelet are disabled at boot. `sudo k8s on` starts them and waits for
the API server; `sudo k8s off` stops every pod sandbox first, then the services, so no container
keeps running behind a stopped containerd.

## ADR-004: keep host swap, pods never swap

**Context.** The host relies on 32 GiB of swap plus systemd-oomd; kubeadm expects swap off.
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

**Context.** One RTX 3090 is shared by two teams through a host dispatcher (`gpu run`): one owner at
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
