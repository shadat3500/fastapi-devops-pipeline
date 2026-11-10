provider "aws" {
  region = var.aws_region

  # Every resource is tagged, so cost and ownership are visible per environment.
  default_tags {
    tags = {
      Project     = "devops-app"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = var.github_repository
    }
  }
}
