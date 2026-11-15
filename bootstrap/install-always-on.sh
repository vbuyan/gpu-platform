#!/usr/bin/env bash
# Keep the cluster running all the time (for monitoring and alerts), but make it the first thing to
# give memory back when the host runs short (ADR-011). Two layers, both on top of the 6.5 GiB cap:
#   1. kubelet eviction: when host memory.available falls under 4 GiB for 30 s (soft) or under 2 GiB
#      (hard), kubelet evicts pods (Prometheus, Grafana, Argo CD...) and taints the node so they do not
#      come back until the pressure is gone. Static control-plane pods stay (~1 GiB).
#   2. systemd-oomd watches kubepods.slice with a 20 % pressure limit, stricter than the 50 % on
#      system.slice, so under real memory pressure the cluster is killed before studio jobs are.
#   containerd and kubelet start at boot. `sudo k8s off` still stops everything by hand.
#   install-always-on.sh              apply
#   install-always-on.sh --rollback   back to on-demand (ADR-003), default eviction, no oomd rule
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root (sudo)"; exit 1; }
LOG=/var/log/gpu-platform-install.log
KCONF=/var/lib/kubelet/config.yaml
DROPIN=/etc/systemd/system/kubepods.slice.d/60-oomd.conf
exec > >(tee -a --output-error=warn "$LOG") 2>&1
echo "=== $(date '+%F %T') $0 ${1:-apply}"
export KUBECONFIG=/etc/kubernetes/admin.conf

set_eviction() {   # set_eviction HARD SOFT|"" : edit the live kubelet config and kubeadm's copy in the cluster
  python3 - "$KCONF" "$1" "$2" <<'PY'
import sys, yaml
path, hard, soft = sys.argv[1], sys.argv[2], sys.argv[3]
c = yaml.safe_load(open(path))
c.setdefault("evictionHard", {})["memory.available"] = hard
if soft:
    c["evictionSoft"] = {"memory.available": soft}
    c["evictionSoftGracePeriod"] = {"memory.available": "30s"}
    c["evictionMaxPodGracePeriod"] = 30
else:
    for k in ("evictionSoft", "evictionSoftGracePeriod", "evictionMaxPodGracePeriod"):
        c.pop(k, None)
open(path, "w").write(yaml.safe_dump(c, sort_keys=False))
PY
  # kubeadm keeps the node's kubelet config in a ConfigMap; keep it equal so upgrades do not revert it
  kubectl -n kube-system create configmap kubelet-config --from-file=kubelet="$KCONF" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  systemctl restart kubelet
}

if [ "${1:-}" = "--rollback" ]; then
  systemctl disable containerd kubelet
  if systemctl is-active -q kubelet; then set_eviction 100Mi ""; fi
  rm -f "$DROPIN"; rmdir "$(dirname "$DROPIN")" 2>/dev/null || true
  systemctl daemon-reload
  systemctl set-property --runtime kubepods.slice ManagedOOMMemoryPressure=auto 2>/dev/null || true
  echo "Back to on-demand: sudo k8s on | sudo k8s off"
  exit 0
fi

[ -f /etc/kubernetes/admin.conf ] || { echo "Install the cluster first (stage 1)"; exit 1; }
systemctl is-active -q kubelet || { echo "Start the cluster first: sudo k8s on"; exit 1; }

echo "1. Start containerd and kubelet at boot"
systemctl enable containerd kubelet

echo "2. kubelet evicts pods when the host is short of memory (soft 4 GiB / 30 s, hard 2 GiB)"
set_eviction 2Gi 4Gi
for i in $(seq 1 60); do kubectl get --raw /readyz >/dev/null 2>&1 && break; sleep 3; done
grep -A1 -E "^eviction(Hard|Soft):" "$KCONF" | sed 's/^/   /'

echo "3. systemd-oomd kills the cluster before studio jobs (kubepods.slice limit 20 %, system.slice 50 %)"
install -d -m 755 "$(dirname "$DROPIN")"
printf '[Slice]\nManagedOOMMemoryPressure=kill\nManagedOOMMemoryPressureLimit=20%%\n' > "$DROPIN"
systemctl daemon-reload
# kubepods.slice is a transient unit created by kubelet; apply now as well, the drop-in covers reboots
systemctl set-property --runtime kubepods.slice ManagedOOMMemoryPressure=kill ManagedOOMMemoryPressureLimit=20%
systemctl show kubepods.slice -p ManagedOOMMemoryPressure -p ManagedOOMMemoryPressureLimit | sed 's/^/   /'
oomctl 2>/dev/null | grep -A1 kubepods | sed 's/^/   /' || true

echo
echo "=== The cluster now runs all the time and yields memory first. Back to on-demand: $0 --rollback"
