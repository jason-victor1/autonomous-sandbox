terraform {
  required_version = ">= 1.8.0"

  backend "s3" {
    bucket         = "autonomous-sandbox-tfstate-478076837031"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "autonomous-sandbox"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

provider "tls" {}
