output "instance_id" {
  description = "EC2 instance ID (GitHub variable EC2_INSTANCE_ID for SSM deploys)."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IP of the instance."
  value       = aws_instance.app.public_ip
}

output "app_url" {
  description = "App URL."
  value       = "http://${aws_instance.app.public_ip}:${var.app_port}"
}

output "log_group" {
  description = "CloudWatch log group receiving container logs."
  value       = aws_cloudwatch_log_group.app.name
}

output "github_deploy_role_arn" {
  description = "Role ARN for aws-actions/configure-aws-credentials (GitHub variable AWS_ROLE_ARN)."
  value       = aws_iam_role.github_deploy.arn
}

output "security_group_id" {
  description = "Security group ID."
  value       = aws_security_group.app.id
}
