# The cluster-side bootstrap that bootstrap/install-argocd.sh used to do by hand:
# install Argo CD once, then hand everything to Git through the root Application.
provider "helm" {
  kubernetes = { config_path = var.kubeconfig }
}

provider "kubernetes" {
  config_path = var.kubeconfig
}

locals {
  repo = abspath("${path.module}/../..")
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  values           = [file("${local.repo}/bootstrap/argocd-values.yaml")]
  wait             = true

  lifecycle {
    # Bootstrap only. After the first install Argo CD manages its own release from
    # gitops/apps/argocd.yaml (ADR-008); Terraform must not fight it over versions or values.
    # (not `all`: an imported release has no repository in state, and with `all` the provider
    # resolves the chart from state and fails; ignore only what Argo CD owns)
    ignore_changes = [version, values, description, create_namespace]
  }
}

resource "kubernetes_manifest" "root" {
  manifest = yamldecode(file("${local.repo}/gitops/root-app.yaml"))

  field_manager {
    name            = "terraform"
    force_conflicts = true # take over the fields first applied with kubectl
  }

  depends_on = [helm_release.argocd]
}
