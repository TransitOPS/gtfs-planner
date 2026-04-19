locals {
  efs_port = 2049
}

resource "aws_s3_bucket" "uploads" {
  bucket_prefix = "${var.name}-uploads"

  force_destroy = var.is_temporary

  # checkov:skip=CKV_AWS_18:TODO access logging
  # checkov:skip=CKV_AWS_144:TODO cross-region replication
  # checkov:skip=CKV2_AWS_62:don't worry about events
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = "aws/s3"
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket     = aws_s3_bucket.uploads.id
  depends_on = [aws_s3_bucket_versioning.uploads]

  rule {
    id     = "expire-aborted-multipart-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning is required to use S3 Files
resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_iam_role" "uploads" {
  name               = aws_s3_bucket.uploads.bucket
  assume_role_policy = data.aws_iam_policy_document.uploads_assume_role.minified_json
}

resource "aws_iam_role_policy" "uploads_read_write" {
  name   = "uploads-read-write"
  role   = aws_iam_role.uploads.id
  policy = data.aws_iam_policy_document.uploads_read_write.minified_json
}

data "aws_iam_policy_document" "uploads_assume_role" {
  statement {
    sid    = "AllowS3FilesAssumeRole"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["elasticfilesystem.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:s3files:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:file-system/*"]
    }
  }
}

data "aws_iam_policy_document" "uploads_read_write" {
  statement {
    sid    = "S3BucketPermissions"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions"
    ]
    resources = [aws_s3_bucket.uploads.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "S3ObjectPermissions"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject*",
      "s3:HeadObject",
      "s3:GetObject*",
      "s3:List*",
      "s3:PutObject*"
    ]
    resources = ["${aws_s3_bucket.uploads.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "UseKmsKeyWithS3Files"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo"
    ]
    resources = ["arn:aws:kms:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]

    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values = [
        aws_s3_bucket.uploads.arn,
        "${aws_s3_bucket.uploads.arn}/*"
      ]
    }
  }

  statement {
    sid    = "EventBridgeManage"
    effect = "Allow"
    actions = [
      "events:DeleteRule",
      "events:DisableRule",
      "events:EnableRule",
      "events:PutRule",
      "events:PutTargets",
      "events:RemoveTargets"
    ]
    resources = ["arn:aws:events:*:*:rule/DO-NOT-DELETE-S3-Files*"]

    condition {
      test     = "StringEquals"
      variable = "events:ManagedBy"
      values   = ["elasticfilesystem.amazonaws.com"]
    }
  }

  statement {
    sid    = "EventBridgeRead"
    effect = "Allow"
    actions = [
      "events:DescribeRule",
      "events:ListRuleNamesByTarget",
      "events:ListRules",
      "events:ListTargetsByRule"
    ]
    resources = ["arn:aws:events:*:*:rule/*"]
  }
}

resource "aws_s3files_file_system" "uploads" {
  bucket   = aws_s3_bucket.uploads.arn
  role_arn = aws_iam_role.uploads.arn

  tags = {
    Name = aws_s3_bucket.uploads.bucket
  }
  depends_on = [
    aws_s3_bucket_versioning.uploads
  ]
}

resource "aws_s3files_mount_target" "uploads" {
  for_each       = toset(var.task_subnet_ids)
  file_system_id = aws_s3files_file_system.uploads.id
  subnet_id      = each.value
  security_groups = [
    aws_security_group.uploads.id
  ]
}

resource "aws_security_group" "uploads" {
  name        = "${aws_s3_bucket.uploads.bucket}-files-sg"
  description = "Security group allowing S3Files access to the ${aws_s3_bucket.uploads.bucket} bucket"
  vpc_id      = data.aws_security_group.external_db.vpc_id

  tags = {
    Name = "${aws_s3_bucket.uploads.bucket}-files-sg"
  }

  lifecycle {
    create_before_destroy = true
  }

  # checkov:skip=CKV2_AWS_5 attached to aws_s3files_mount_target above
}

resource "aws_security_group_rule" "uploads_efs" {
  security_group_id        = aws_security_group.uploads.id
  type                     = "ingress"
  description              = "Allow incoming access to EFS"
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.this.id
  from_port                = local.efs_port
  to_port                  = local.efs_port
}
