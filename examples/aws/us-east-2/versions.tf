provider "aws" {
  alias = "us_east_2"
  region     = "us-east-2"
  profile = "my"
  # access_key = var.aws_access_key
  # secret_key = var.aws_secret_key
  # token      = var.aws_token
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"  # Specify your desired version
    }
  }
}
