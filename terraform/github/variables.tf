variable "owner" {
  description = "GitHub account that owns the repository."
  type        = string
  default     = "vbuyan"
}

variable "required_checks" {
  description = "CI jobs that must pass before anything lands on main."
  type        = list(string)
  default     = ["lint-and-test", "manifests", "admission-policy", "terraform"]
}
