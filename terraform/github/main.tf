# The repository itself as code: description, topics, security features, and a protected main.
resource "github_repository" "platform" {
  name        = "gpu-platform"
  description = "Kubernetes platform for generative-media workloads on a shared GPU workstation: kubeadm, Cilium, Argo CD, memory caps, GPU via a shared queue"
  visibility  = "public"
  topics      = ["kubernetes", "kubeadm", "cilium", "argocd", "gitops", "gpu", "platform-engineering", "devops", "terraform", "prometheus"]

  has_issues             = true
  has_wiki               = false
  has_projects           = false
  delete_branch_on_merge = true
  allow_merge_commit     = false
  allow_rebase_merge     = true
  allow_squash_merge     = true

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "github_branch_protection" "main" {
  repository_id = github_repository.platform.node_id
  pattern       = "main"

  required_status_checks {
    strict   = false
    contexts = var.required_checks
  }

  required_linear_history = true
  allows_force_pushes     = false
  allows_deletions        = false
  # The owner can still push a hotfix; everyone else goes through a pull request with green CI.
  enforce_admins = false
}

resource "github_repository_vulnerability_alerts" "platform" {
  repository = github_repository.platform.name
  enabled    = true
}
