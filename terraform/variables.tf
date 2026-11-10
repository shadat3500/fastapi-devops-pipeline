variable "environment" {
  description = "Deployment environment name."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be \"staging\" or \"production\"."
  }
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "Optional AMI override. Empty = latest Amazon Linux 2023 (x86_64) looked up via SSM."
  type        = string
  default     = ""
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 10
}

variable "app_image" {
  description = "Container image repository (without tag)."
  type        = string
  default     = "ghcr.io/shadat3500/fastapi-devops-pipeline"
}

variable "app_image_tag" {
  description = "Image tag started at first boot. Later releases are rolled out by CD (SSM)."
  type        = string
  default     = "1.0.8"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,128}$", var.app_image_tag))
    error_message = "app_image_tag contains invalid characters."
  }
}

variable "app_port" {
  description = "Port the app listens on (host and container)."
  type        = number
  default     = 8080
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the app port. Narrow this (e.g. to a load balancer or office IP) in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for container logs."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs accepts."
  }
}

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to assume the deploy role via OIDC."
  type        = string
  default     = "shadat3500/fastapi-devops-pipeline"
}

variable "create_github_oidc_provider" {
  description = "Create the account-wide GitHub OIDC provider. Only ONE environment per AWS account should set this to true; the other reuses it."
  type        = bool
  default     = false
}
