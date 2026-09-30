# --- Current Account Context ---
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- Customer Managed KMS Key (CMK) ---
resource "aws_kms_key" "data_key" {
  description             = "Customer Managed Key for AI Platform model artifacts and vector data"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "ai-platform-cmk"
  }
}

resource "aws_kms_alias" "data_key_alias" {
  name          = "alias/ai-platform-${var.environment}-key"
  target_key_id = aws_kms_key.data_key.key_id
}

# --- Encrypted Artifact Storage ---
resource "aws_s3_bucket" "model_storage" {
  #checkov:skip=CKV_AWS_18: "Access logging disabled for sandbox model bucket"
  #checkov:skip=CKV_AWS_144: "Cross-region replication not required for sandbox"
  #checkov:skip=CKV_AWS_300: "Lifecycle rules not required for sandbox artifacts"
  #checkov:skip=CKV2_AWS_62: "Event notifications configured in Phase 3"
  #checkov:skip=CKV2_AWS_61: "Lifecycle configuration not required for sandbox"

  bucket_prefix = "${var.bucket_prefix}-${var.environment}-"
  force_destroy = true

  tags = {
    Name        = "${var.bucket_prefix}-${var.environment}"
    Tier        = "data-perimeter"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "model_storage" {
  bucket = aws_s3_bucket.model_storage.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_storage" {
  bucket = aws_s3_bucket.model_storage.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.data_key.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "model_storage" {
  bucket = aws_s3_bucket.model_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Bucket Policy: Strict TLS Enforcement ---
resource "aws_s3_bucket_policy" "enforce_tls" {
  bucket = aws_s3_bucket.model_storage.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonTLSRequests"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.model_storage.arn,
          "${aws_s3_bucket.model_storage.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}
