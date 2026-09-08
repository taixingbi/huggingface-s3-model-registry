# -----------------------------------------------------------------------------
# S3 bucket used as the Hugging Face model registry.
#
# Layout (prefixes, not real "folders"):
#   inference/<model-id>/...
#   embedding/<model-id>/...
#   reranker/<model-id>/...
#   classifier/<model-id>/...
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "model_registry" {
  bucket = local.bucket_name

  # Model artifacts can be large; disallow accidental force-destroy in prod.
  force_destroy = false
}

resource "aws_s3_bucket_ownership_controls" "model_registry" {
  bucket = aws_s3_bucket.model_registry.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "model_registry" {
  bucket = aws_s3_bucket.model_registry.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "model_registry" {
  bucket = aws_s3_bucket.model_registry.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_registry" {
  bucket = aws_s3_bucket.model_registry.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "model_registry" {
  bucket = aws_s3_bucket.model_registry.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Placeholder "folder" markers so the prefixes show up immediately in the
# console before the first sync runs. Purely cosmetic — S3 has no real
# directories, and sync_models.py works fine without these.
resource "aws_s3_object" "type_prefix_markers" {
  for_each = toset(var.model_type_prefixes)

  bucket       = aws_s3_bucket.model_registry.id
  key          = "${each.value}/.keep"
  content      = ""
  content_type = "text/plain"
}

output "bucket_name" {
  description = "Name of the S3 model registry bucket."
  value       = aws_s3_bucket.model_registry.id
}

output "bucket_arn" {
  value = aws_s3_bucket.model_registry.arn
}
