# Bootstrap: creates the S3 bucket that will hold the MAIN config's remote
# state. This config itself uses LOCAL state (terraform.tfstate right here),
# because the bucket can't store its own state before it exists — the
# chicken-and-egg problem. You run this ONCE, up front.

terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# A globally-unique bucket name. S3 bucket names share one global namespace
# across ALL AWS accounts, so "tf-state" would collide. We suffix with the
# account ID to guarantee uniqueness without hardcoding a random string.
data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "aiops-poc-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  # Safety net: don't let `terraform destroy` nuke the bucket holding all
  # your state. You'd have to remove this line deliberately to delete it.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Project = "aiops-poc"
    Purpose = "terraform-remote-state"
  }
}

# Versioning is REQUIRED for safe state management. Every apply overwrites
# the state object; versioning keeps prior versions so you can recover from
# a corrupted or accidentally-truncated state. The native lock also relies
# on a clean object history.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest. State files contain secrets in plaintext (RDS
# passwords, etc.), so this is non-negotiable, not nice-to-have.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block ALL public access. State is the crown jewels; it must never be
# reachable publicly under any ACL or policy mistake.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket_name" {
  value       = aws_s3_bucket.tfstate.id
  description = "Put this bucket name into the main config's backend block."
}