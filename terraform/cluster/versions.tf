terraform {
  required_version = ">= 1.10"
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 3.3" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.5" }
  }
  # State lives in the cluster it describes: a Secret in kube-system, locked through a Lease.
  # No cloud bucket, nothing on the laptop.
  backend "kubernetes" {
    secret_suffix = "cluster"
    namespace     = "kube-system"
    config_path   = "~/.kube/config"
  }
}
