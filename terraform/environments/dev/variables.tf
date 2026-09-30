variable "aws_region" {
  description = "Target AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "Target GitHub Organization or Username"
  type        = string
}

variable "github_repo" {
  description = "Target GitHub Repository"
  type        = string
  default     = "autonomous-sandbox"
}
