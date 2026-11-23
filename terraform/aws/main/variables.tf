# -----------------------------------------------------------------------------
# Input variables for the main stack.
# Override defaults in terraform.tfvars (git-ignored) if needed.
# -----------------------------------------------------------------------------

variable "region" {
  description = "AWS region for every resource in this stack. Locked to eu-north-1 by the organisation's SCP (see decision 009)."
  type        = string
  default     = "eu-north-1"

  validation {
    condition     = var.region == "eu-north-1"
    error_message = "This account's SCP only allows eu-north-1. See docs/decisions.md (009)."
  }
}

variable "raw_bucket_name" {
  description = "The name of the S3 bucket to create for raw data. Must be globally unique."
  type        = string
  default     = "uk-property-platform-raw-data"
}