terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

  # Remote state in the bootstrap-created bucket. Native S3 locking via
  # use_lockfile (no DynamoDB needed).
  backend "s3" {
    bucket       = "aiops-poc-tfstate-681721397035"
    key          = "aiops-poc/infra.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "aiops-poc"
      ManagedBy = "terraform"
    }
  }
}