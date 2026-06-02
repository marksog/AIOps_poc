# versions.tf — pin provider versions so your infra is reproducible.
# An interviewer will ask "how do you keep Terraform reproducible?" — this is the answer.
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state on S3. Uncomment after creating the bucket (see README).
  # S3 now supports native state locking (use_lockfile) — no DynamoDB needed,
  # which mirrors what you learned about Azure blob lease locking.
  # backend "s3" {
  #   bucket       = "YOUR-TFSTATE-BUCKET"
  #   key          = "project1/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "aiops-control-plane"
      ManagedBy = "terraform"
    }
  }
}
