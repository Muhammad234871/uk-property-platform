output "raw_bucket_name" {
  description = "Raw data bucket; set as RAW_BUCKET in .env"
  value       = aws_s3_bucket.raw.bucket
}

output "raw_bucket_arn" {
  description = "ARN of the raw bucket; used by the pipeline IAM policy"
  value       = aws_s3_bucket.raw.arn
}