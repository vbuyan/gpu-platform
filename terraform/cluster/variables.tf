variable "kubeconfig" {
  description = "Path to the kubeconfig of the station cluster."
  type        = string
  default     = "~/.kube/config"
}

variable "argocd_chart_version" {
  description = "argo-cd chart used for the first install. Later upgrades are a commit to gitops/apps/argocd.yaml."
  type        = string
  default     = "10.18.0"
}
