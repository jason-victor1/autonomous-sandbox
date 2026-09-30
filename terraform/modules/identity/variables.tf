variable "github_org" {
  description = "GitHub organization or user account"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "role_name" {
  description = "Name of the IAM role assumed by GitHub Actions"
  type        = string
  default     = "gh-actions-deployer-role"
}

variable "max_session_duration" {
  description = "Maximum duration of STS session in seconds (max 3600 for CI/CD)"
  type        = number
  default     = 3600
}
