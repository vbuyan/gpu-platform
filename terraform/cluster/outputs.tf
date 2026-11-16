output "argocd_release" {
  description = "Argo CD release as first installed (Argo CD upgrades itself afterwards)."
  value       = "${helm_release.argocd.namespace}/${helm_release.argocd.name} chart ${helm_release.argocd.version}"
}

output "gitops_source" {
  description = "Where the cluster takes its desired state from."
  value       = "${kubernetes_manifest.root.manifest.spec.source.repoURL} ${kubernetes_manifest.root.manifest.spec.source.path}"
}
