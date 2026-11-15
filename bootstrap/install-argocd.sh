#!/usr/bin/env bash
# Stage 2: install Argo CD and hand the cluster over to Git (app of apps).
# Runs as the operator (no root): needs a running cluster (`sudo k8s on`) and ~/.kube/config.
#   bootstrap/install-argocd.sh            install or upgrade Argo CD, apply the root Application
#   bootstrap/install-argocd.sh --remove   delete the root Application and Argo CD
set -euo pipefail
ARGOCD_CHART_VERSION=10.18.0   # Argo CD v3.6.1
REPO=$(cd "$(dirname "$0")/.." && pwd)

if [ "${1:-}" = "--remove" ]; then
  kubectl -n argocd delete application root --ignore-not-found --wait=false
  helm uninstall argocd -n argocd --ignore-not-found
  kubectl delete namespace argocd --ignore-not-found
  exit 0
fi

kubectl get --raw /readyz >/dev/null || { echo "Cluster is not running: sudo k8s on"; exit 1; }
REPO_URL=$(grep -m1 'repoURL: https://github.com' "$REPO/gitops/root-app.yaml" | awk '{print $2}')
case "$REPO_URL" in *REPLACE_ME*|"") echo "Set the GitHub URL first: bin/set-repo-url <url>"; exit 1 ;; esac
git ls-remote "$REPO_URL" HEAD >/dev/null 2>&1 || { echo "$REPO_URL is not reachable; push the repo first"; exit 1; }

echo "1. Argo CD $ARGOCD_CHART_VERSION"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  -n argocd --create-namespace -f "$REPO/bootstrap/argocd-values.yaml" --wait --timeout 10m

echo "2. Root Application: from now on the cluster follows $REPO_URL"
kubectl apply -f "$REPO/gitops/root-app.yaml"

echo
echo "UI:  ssh -L 8080:localhost:8080 station 'kubectl -n argocd port-forward svc/argocd-server 8080:80'"
echo "     then open http://localhost:8080, user admin, password:"
echo "     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
