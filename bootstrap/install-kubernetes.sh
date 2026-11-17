#!/usr/bin/env bash
# Install a single-node kubeadm Kubernetes cluster on a shared GPU workstation.
#
# Design constraints (see docs/decisions.md):
#   - The host is production: two teams share it, RAM is the bottleneck, access is remote over Tailscale.
#   - The whole cluster (control plane + workloads) is capped by the kubepods cgroup (host memory minus systemReserved).
#   - The cluster runs on demand: containerd and kubelet do not start at boot (`k8s on` / `k8s off`).
#   - Host swap stays on (kubelet: failSwapOn=false, swapBehavior=NoSwap).
#   - A dead man's switch rolls everything back in 20 minutes unless the operator confirms
#     that SSH over Tailscale still works (`--confirm`).
#
# Usage (as root):
#   install-kubernetes.sh            install, then arm the 20-minute auto-rollback
#   install-kubernetes.sh --confirm  keep the cluster (cancel auto-rollback)
#   install-kubernetes.sh --rollback remove everything this script installed
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root (sudo)"; exit 1; }
trap '' HUP

K8S_VERSION=v1.37.2
K8S_MINOR=v1.37
CILIUM_VERSION=1.20.4
HELM_VERSION=v4.3.2
OPERATOR=${SUDO_USER:?run with sudo from the operator account}
OPERATOR_HOME=$(getent passwd "$OPERATOR" | cut -d: -f6)
REPO=$(cd "$(dirname "$0")/.." && pwd)
LOG=/var/log/gpu-platform-install.log
TIMER=gpu-platform-auto-rollback
POD_CIDR=10.244.0.0/16

exec > >(tee -a --output-error=warn "$LOG") 2>&1
echo "=== $(date '+%F %T') $0 ${1:-install}"

# ------------------------------------------------------------------ rollback
rollback() {
  echo "Rolling back the Kubernetes install"
  systemctl stop "$TIMER.timer" "$TIMER-install.timer" 2>/dev/null || true
  if command -v kubeadm >/dev/null; then kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock || true; fi
  if command -v crictl >/dev/null && systemctl is-active -q containerd; then
    crictl --runtime-endpoint unix:///run/containerd/containerd.sock rmp -fa || true
  fi
  systemctl stop kubelet containerd 2>/dev/null || true
  systemctl disable kubelet containerd 2>/dev/null || true
  for l in cilium_host cilium_net cilium_vxlan cilium_geneve; do ip link delete "$l" 2>/dev/null || true; done
  for t in iptables ip6tables; do
    command -v "$t-save" >/dev/null || continue
    "$t-save" | grep -v -E 'KUBE|CILIUM' | "$t-restore" || true
  done
  if command -v ufw >/dev/null; then   # remove only the rules this installer added
    while n=$(ufw status numbered | awk -F'[][]' '/gpu-platform/ {gsub(/ /,"",$2); print $2; exit}'); [ -n "$n" ]; do
      ufw --force delete "$n" >/dev/null
    done
  fi
  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get purge -y kubeadm kubelet kubectl cri-tools kubernetes-cni containerd 2>/dev/null || true
  rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni /opt/cni /var/lib/cni \
         /etc/containerd /var/lib/containerd /var/run/cilium /sys/fs/bpf/cilium "$OPERATOR_HOME/.kube" \
         /etc/apt/sources.list.d/kubernetes.list /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
         /etc/modules-load.d/gpu-platform.conf /etc/sysctl.d/90-gpu-platform.conf \
         /usr/local/bin/helm /usr/local/bin/k8s /etc/sudoers.d/gpu-platform-k8s
  systemctl daemon-reload
  echo "Rollback finished. Host is back to its pre-install state."
}

case "${1:-}" in
  --rollback) rollback; exit 0 ;;
  --confirm)
    if systemctl is-active -q "$TIMER.timer"; then
      systemctl stop "$TIMER.timer"; echo "Auto-rollback cancelled. The cluster stays."
    elif systemctl is-active -q "$TIMER-install.timer"; then
      echo "The install has not finished (or failed): nothing to confirm."
      echo "The install-time auto-rollback is still armed. See $LOG, or run --rollback now."
      exit 1
    else echo "No pending auto-rollback."; fi
    exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1"; exit 2 ;;
esac

# ------------------------------------------------------------------ 0. preflight
echo "0. Preflight"
[ -f /etc/kubernetes/admin.conf ] && { echo "Already installed (/etc/kubernetes/admin.conf). Nothing to do."; exit 0; }
systemctl is-active -q tailscaled || { echo "tailscaled is not running; refusing to touch networking"; exit 1; }
free_gb=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
[ "$free_gb" -ge 30 ] || { echo "Only ${free_gb} GB free on /, need 30"; exit 1; }
avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
[ "$avail_mb" -ge 3500 ] || { echo "Only ${avail_mb} MB RAM available; run when the station is less busy"; exit 1; }
NODE_IP=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
TS_IP=$(tailscale ip -4 | head -1)
if [ -z "$NODE_IP" ] || [ -z "$TS_IP" ]; then echo "Cannot detect node or Tailscale IP"; exit 1; fi
echo "   node IP $NODE_IP, Tailscale IP $TS_IP, ${free_gb} GB disk, ${avail_mb} MB RAM available"
# a half-configured package makes every apt-get install fail halfway; refuse before touching anything
broken=$(dpkg --audit 2>&1 || true)
if [ -n "$broken" ] || ! apt-get check -qq >/dev/null 2>&1; then
  echo "The package system is not clean, fix it first (nothing was changed):"
  echo "$broken" | head -20
  exit 1
fi

# arm the dead man's switch first: if anything below breaks remote access, the host heals itself
arm() {  # arm <unit> <minutes>; replaces a timer left over from an earlier run
  systemctl stop "$1.timer" 2>/dev/null || true
  systemctl reset-failed "$1.timer" "$1.service" 2>/dev/null || true
  systemd-run --unit="$1" --on-active="$2min" --timer-property=AccuracySec=10s \
    /bin/bash "$REPO/bootstrap/install-kubernetes.sh" --rollback >/dev/null
}
arm "$TIMER-install" 45
echo "   auto-rollback armed: 45 minutes for the install itself"
trap 'echo; echo "INSTALL FAILED (line $LINENO). Auto-rollback runs in up to 45 min; to clean up now:";
      echo "  sudo bash $REPO/bootstrap/install-kubernetes.sh --rollback"' ERR

# ------------------------------------------------------------------ 1. kernel
echo "1. Kernel modules and sysctl"
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/gpu-platform.conf
modprobe overlay; modprobe br_netfilter
cat > /etc/sysctl.d/90-gpu-platform.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# ------------------------------------------------------------------ 1b. host firewall
# The host blocks its own outbound traffic to private ranges on the LAN port (it may not reach
# home devices). Cluster traffic trips over that: a Service IP (10.96.x) is routed to the LAN port
# before kube-proxy rewrites it to the node's own address, so the packet is dropped. Add narrow
# exceptions, tagged so --rollback removes exactly these. Pods still cannot reach home devices.
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  echo "1b. Host firewall exceptions for the cluster (ufw)"
  LAN_IF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
  C=(comment gpu-platform)
  ufw insert 1 allow out on "$LAN_IF" to "$NODE_IP" "${C[@]}" >/dev/null           # node to itself via a Service IP
  ufw insert 1 allow out on "$LAN_IF" to 10.96.0.0/12 "${C[@]}" >/dev/null         # Service IPs before DNAT
  ufw insert 1 allow out on "$LAN_IF" to "$POD_CIDR" "${C[@]}" >/dev/null          # pod IPs before DNAT
  ufw allow in from "$POD_CIDR" "${C[@]}" >/dev/null                               # pods to the API server, kubelet
  ufw route deny from "$POD_CIDR" to 192.168.0.0/16 "${C[@]}" >/dev/null           # pods never reach the home LAN
  ufw route deny from "$POD_CIDR" to 172.16.0.0/12 "${C[@]}" >/dev/null
  ufw route deny from "$POD_CIDR" to 100.64.0.0/10 "${C[@]}" >/dev/null            # nor the tailnet
  ufw route allow from "$POD_CIDR" "${C[@]}" >/dev/null                            # pods to the internet
  ufw status numbered | grep gpu-platform | sed 's/^/   /'
fi

# ------------------------------------------------------------------ 2. containerd
echo "2. containerd (Ubuntu package) with the systemd cgroup driver"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends containerd apt-transport-https ca-certificates curl gpg
install -d /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || { echo "Could not enable SystemdCgroup"; exit 1; }
systemctl restart containerd

# ------------------------------------------------------------------ 3. kubeadm, kubelet, kubectl
echo "3. kubeadm / kubelet / kubectl $K8S_VERSION from pkgs.k8s.io"
install -d -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
DEBIAN_FRONTEND=noninteractive apt-get update -qq
pkgver="${K8S_VERSION#v}-*"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  "kubelet=$pkgver" "kubeadm=$pkgver" "kubectl=$pkgver"
apt-mark hold kubelet kubeadm kubectl >/dev/null

# ------------------------------------------------------------------ 4. helm
echo "4. Helm $HELM_VERSION"
tmp=$(mktemp -d)
curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" -o "$tmp/helm.tgz"
curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz.sha256sum" -o "$tmp/helm.sha"
(cd "$tmp" && echo "$(awk '{print $1}' helm.sha)  helm.tgz" | sha256sum -c --quiet)
tar -xzf "$tmp/helm.tgz" -C "$tmp" && install -m 755 "$tmp/linux-amd64/helm" /usr/local/bin/helm
rm -rf "$tmp"

# ------------------------------------------------------------------ 5. kubeadm init
echo "5. kubeadm init (control plane, memory-capped kubelet)"
sed -e "s|__NODE_IP__|$NODE_IP|g" -e "s|__TS_IP__|$TS_IP|g" -e "s|__K8S_VERSION__|$K8S_VERSION|g" \
    -e "s|__POD_CIDR__|$POD_CIDR|g" -e "s|__HOSTNAME__|$(hostname)|g" "$REPO/bootstrap/kubeadm-config.yaml" > /root/kubeadm-config.yaml
kubeadm init --config /root/kubeadm-config.yaml --ignore-preflight-errors=Swap
install -d -o "$OPERATOR" -g "$OPERATOR" "$OPERATOR_HOME/.kube"
install -m 600 -o "$OPERATOR" -g "$OPERATOR" /etc/kubernetes/admin.conf "$OPERATOR_HOME/.kube/config"
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null || true

# ------------------------------------------------------------------ 6. CNI
echo "6. Cilium $CILIUM_VERSION (CNI)"
helm repo add cilium https://helm.cilium.io >/dev/null
helm repo update cilium >/dev/null
helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system \
  -f "$REPO/bootstrap/cilium-values.yaml" --wait --timeout 10m
kubectl wait --for=condition=Ready node --all --timeout=5m

# ------------------------------------------------------------------ 7. on-demand control + verification
echo "7. On-demand control and smoke test"
install -m 755 "$REPO/bin/k8s" /usr/local/bin/k8s
cat > /etc/sudoers.d/gpu-platform-k8s <<EOF
# lets the operator start/stop the cluster without a password; nothing else
$OPERATOR ALL=(root) NOPASSWD: /usr/local/bin/k8s
EOF
chmod 440 /etc/sudoers.d/gpu-platform-k8s
visudo -cf /etc/sudoers.d/gpu-platform-k8s >/dev/null
systemctl disable kubelet containerd >/dev/null 2>&1   # do not start at boot; `k8s on` starts them
kubectl run smoke-dns --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default.svc.cluster.local >/dev/null
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/smoke-dns --timeout=3m && echo "   DNS inside the cluster works"
kubectl delete pod smoke-dns --wait=false >/dev/null
echo "   kubepods memory cap: $(awk '{printf "%.1f GiB", $1/1073741824}' /sys/fs/cgroup/kubepods.slice/memory.max 2>/dev/null)"
kubectl get nodes -o wide
systemctl stop "$TIMER-install.timer" 2>/dev/null || true
arm "$TIMER" 20

cat <<EOF

=== Installed. The cluster is running now.
Check that SSH over Tailscale still works from the laptop, then keep the cluster:
    ssh -t station "sudo bash $REPO/bootstrap/install-kubernetes.sh --confirm"
Without --confirm everything is rolled back automatically in 20 minutes.
Daily use:  sudo k8s on | sudo k8s off | k8s status
EOF
