output "repository" {
  description = "The repository URL."
  value       = github_repository.platform.html_url
}

output "protected_branch_checks" {
  description = "Status checks required on main."
  value       = var.required_checks
}
