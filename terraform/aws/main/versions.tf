terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "uk-property-platform-state-bucket"
    key          = "aws/main.tfstate"
    region       = "eu-north-1"
    profile      = "terraform-admin"
    use_lockfile = true
    encrypt      = true
  }
}