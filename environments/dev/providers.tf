provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      Project     = "asinbase"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}