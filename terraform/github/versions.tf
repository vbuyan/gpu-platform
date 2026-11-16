terraform {
  required_version = ">= 1.10"
  required_providers {
    github = { source = "integrations/github", version = "~> 6.13" }
  }
  backend "kubernetes" {
    secret_suffix = "github"
    namespace     = "kube-system"
    config_path   = "~/.kube/config"
  }
}

# Token from the environment (GITHUB_TOKEN); it never lands in the state.
provider "github" {
  owner = var.owner
}
