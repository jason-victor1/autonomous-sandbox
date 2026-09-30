variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "bucket_prefix" {
  description = "Prefix for the isolated model bucket"
  type        = string
  default     = "sandbox-model-artifacts"
}
