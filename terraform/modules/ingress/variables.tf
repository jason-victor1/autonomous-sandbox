variable "environment" {
  type    = string
  default = "dev"
}

variable "invocation_queue_arn" {
  type        = string
  description = "ARN of the SQS FIFO queue receiving tasks"
}

variable "kms_key_arn" {
  type        = string
  description = "KMS Key ARN encrypting SQS and logs"
}
