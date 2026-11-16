#!/usr/bin/env bash
# Render everything Argo CD would apply and validate it against Kubernetes and CRD schemas.
# Needs helm and kubeconform on PATH. Used by CI and runnable locally.
set -euo pipefail
cd "$(dirname "$0")/.."
SCHEMAS=(-schema-location default
         -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')
kc() { kubeconform -strict -summary "${SCHEMAS[@]}" "$@"; }
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT

echo "== plain manifests"
kc gitops/root-app.yaml gitops/apps gitops/platform examples

echo "== monitoring extras (kustomize)"
kubectl kustomize gitops/monitoring/extras > "$out/extras.yaml"
kc "$out/extras.yaml"

echo "== Helm charts with this repo's values"
chart_version() { grep -m1 "targetRevision:" "$1" | awk '{print $2}'; }
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
helm template argocd argo/argo-cd --version "$(chart_version gitops/apps/argocd.yaml)" -n argocd \
  -f bootstrap/argocd-values.yaml > "$out/argocd.yaml"
helm template kps prometheus-community/kube-prometheus-stack --version "$(chart_version gitops/apps/monitoring.yaml)" \
  -n monitoring -f gitops/monitoring/values.yaml > "$out/kps.yaml"
# CRDs themselves are huge and not worth validating; everything else is
kc -skip CustomResourceDefinition "$out/argocd.yaml" "$out/kps.yaml"
