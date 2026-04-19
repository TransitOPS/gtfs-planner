resource "aws_s3_bucket" "default" {
  bucket = var.bucket
  lifecycle {
    prevent_destroy = true
  }
  # checkov:skip=CKV_AWS_18:TODO skipping logging for now
  # checkov:skip=CKV_AWS_144:don't nee cross-region replication
  # checkov:skip=CKV2_AWS_62:don't need notifications
}

resource "aws_s3_bucket_versioning" "default" {
  bucket = aws_s3_bucket.default.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
  bucket = aws_s3_bucket.default.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = "aws/s3"
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "default" {
  bucket     = aws_s3_bucket.default.id
  depends_on = [aws_s3_bucket_versioning.default]

  rule {
    id     = "expire-aborted-multipart-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_public_access_block" "default" {
  bucket                  = aws_s3_bucket.default.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "default" {
  bucket = aws_s3_bucket.default.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
