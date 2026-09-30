variable "environment" {
  type    = string
  default = "dev"
}

variable "ecs_cluster_name" {
  type        = string
  description = "Name of the ECS cluster hosting the agent tasks"
}

variable "ecs_cluster_arn" {
  type        = string
  description = "ARN of the ECS cluster hosting the agent tasks"
}

variable "agent_task_role_name" {
  type        = string
  description = "Name of the agent task IAM role to quarantine on breaker trips"
}

variable "agent_task_role_arn" {
  type        = string
  description = "ARN of the agent task IAM role"
}

variable "kms_key_arn" {
  type        = string
  description = "KMS Key ARN for SQS queue encryption"
}
