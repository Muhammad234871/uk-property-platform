resource "aws_s3_bucket" "raw" {
  bucket = var.raw_bucket_name
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket = aws_s3_bucket.raw.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  # Raw files are the permanent source of truth (decision 002), so they are
  # never deleted, only moved to cheaper storage as they age.
  rule {
    id     = "raw-tiering"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # Glacier Instant Retrieval: cheap, but still readable straight away,
    # so Databricks can reprocess old months without a restore step.
    transition {
      days          = 180
      storage_class = "GLACIER_IR"
    }

    # Idempotent re-loads overwrite files, leaving old versions behind.
    # Keep them for 30 days (to undo a bad load), then delete them.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # A failed multipart upload (e.g. during the 5 GB backfill) leaves hidden
  # parts in the bucket that still cost money. Clean them up after 7 days.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Lifecycle rules on a versioned bucket need versioning to exist first.
  depends_on = [aws_s3_bucket_versioning.raw]
}