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

variable "monthly_cost_limit" {
  description = "Monthly AWS budget in USD. Alerts fire at 30% and 50% actual spend, and at 100% forecast."
  type        = number
  default     = 10
}

variable "budget_notification_email" {
  description = "Email address that receives budget alerts. Set it in terraform.tfvars (git-ignored)."
  type        = string
  sensitive   = true
}