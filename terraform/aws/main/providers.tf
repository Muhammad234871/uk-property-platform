# -----------------------------------------------------------------------------
# AWS provider for the main stack.
# Everything in this stack is created in var.region (eu-north-1, see decision 009).
# -----------------------------------------------------------------------------

provider "aws" {
  region  = var.region
  profile = "terraform-admin"

  # Added automatically to every resource that supports tags,
  # so resources can be found and costed by project.
  default_tags {
    tags = {
      project     = "uk-property-platform"
      managed_by  = "terraform"
      environment = "dev"
      repo        = "github.com/Muhammad234871/uk-property-platform"
    }
  }
}
