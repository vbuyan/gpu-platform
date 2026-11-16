# The cluster existed before Terraform: adopt it instead of recreating it (ADR-012).
import {
  to = helm_release.argocd
  id = "argocd/argocd"
}

import {
  to = kubernetes_manifest.root
  id = "apiVersion=argoproj.io/v1alpha1,kind=Application,namespace=argocd,name=root"
}
