variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where compute and endpoints are deployed"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR for internal traffic routing"
}

variable "isolated_subnet_ids" {
  type        = list(string)
  description = "Isolated subnets hosting ECS tasks and interface endpoints"
}

variable "isolated_route_table_id" {
  type        = string
  description = "Route table ID for isolated subnets (to attach S3 Gateway Endpoint)"
}

variable "model_bucket_arn" {
  type        = string
  description = "ARN of the model artifact S3 bucket"
}

variable "kms_key_arn" {
  type        = string
  description = "KMS Key ARN encrypting S3 artifacts"
}
