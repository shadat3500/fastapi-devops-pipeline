environment                 = "staging"
aws_region                  = "us-east-1"
instance_type               = "t3.micro" # free-tier eligible
root_volume_size_gb         = 10
app_image_tag               = "1.0.8"
log_retention_days          = 7
allowed_ingress_cidrs       = ["0.0.0.0/0"]
create_github_oidc_provider = true # staging is applied first and owns the account-wide provider
