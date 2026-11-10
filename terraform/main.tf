locals {
  name           = "devops-app-${var.environment}"
  log_group_name = "/devops-app/${var.environment}/app"
  ami_id         = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.al2023_ami[0].value
}

# ---------------------------------------------------------------- network ----
# The default VPC is acceptable for this single-instance target (see README).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Latest Amazon Linux 2023, resolved via AWS's public SSM parameter (no hardcoded AMI IDs).
data "aws_ssm_parameter" "al2023_ami" {
  count = var.ami_id == "" ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "app" {
  name        = "${local.name}-sg"
  description = "devops-app ${var.environment}: app port only. No SSH - access is via SSM Session Manager."
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${local.name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "app" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.app.id
  description       = "App HTTP"
  ip_protocol       = "tcp"
  from_port         = var.app_port
  to_port           = var.app_port
  cidr_ipv4         = each.value
}

# Outbound HTTPS only: pulling images (GHCR), packages, and the SSM/CloudWatch endpoints.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS egress (image pulls, OS packages, SSM, CloudWatch)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# DNS is served by the VPC resolver; HTTP for distro mirrors that redirect.
resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP egress (package mirrors)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------- logging ----
resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}

# -------------------------------------------------------------------- IAM ----
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  description        = "devops-app ${var.environment} EC2 instance role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM agent: lets CD run commands (aws ssm send-command) and humans open sessions
# without SSH keys or an open port 22.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Docker awslogs driver: write ONLY to this environment's log group.
data "aws_iam_policy_document" "logs" {
  statement {
    sid       = "WriteContainerLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "logs" {
  name   = "cloudwatch-logs-write"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.logs.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# -------------------------------------------------------------------- EC2 ----
resource "aws_instance" "app" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = true
  monitoring                  = var.environment == "production"

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region     = var.aws_region
    environment    = var.environment
    log_group_name = aws_cloudwatch_log_group.app.name
    image          = "${var.app_image}:${var.app_image_tag}"
    app_port       = var.app_port
  })

  # IMDSv2 only: blocks SSRF-style credential theft via the metadata service.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # containers on the host may need IMDS (awslogs driver runs in dockerd, hop 1)
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = local.name }

  lifecycle {
    # A newer AL2023 AMI shouldn't silently replace a running server; roll AMIs deliberately.
    ignore_changes = [ami]
  }
}
