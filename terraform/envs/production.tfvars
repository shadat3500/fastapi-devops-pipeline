environment         = "production"
aws_region          = "us-east-1"
instance_type       = "t3.small"
root_volume_size_gb = 20
app_image_tag       = "1.0.8"
log_retention_days  = 30
# In real production put an ALB in front and allow only its security group / CIDR.
allowed_ingress_cidrs       = ["0.0.0.0/0"]
create_github_oidc_provider = false # reuses the provider created by staging
