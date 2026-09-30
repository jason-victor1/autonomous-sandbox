output "bucket_id" {
  description = "ID of the secure model storage S3 bucket"
  value       = aws_s3_bucket.model_storage.id
}

output "bucket_arn" {
  description = "ARN of the secure model storage S3 bucket"
  value       = aws_s3_bucket.model_storage.arn
}

output "kms_key_arn" {
  description = "ARN of the Customer Managed Key"
  value       = aws_kms_key.data_key.arn
}

output "kms_key_id" {
  description = "ID of the Customer Managed Key"
  value       = aws_kms_key.data_key.key_id
}
