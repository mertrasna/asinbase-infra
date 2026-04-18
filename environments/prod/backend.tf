terraform {
  required_version = "~> 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.40"
    }
  }

  backend "s3" {
    bucket       = "asinbase-tfstate-eu-central-1-d2d3980f"
    key          = "environments/prod/terraform.tfstate" # s3 works like key-value pairs
    region       = "eu-central-1"                       # frankfurt
    encrypt      = true                                 # encryption at rest
    use_lockfile = true 
  }
}  