terraform {
  # Compatible with both Terraform and OpenTofu
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    (var.tag_name) = var.tag_value
  }

  name_prefix = "bytecat-${var.application_name}"
}

# -----------------------------------------------------------------------------
# S3 BUCKETS
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "scripts" {
  bucket = coalesce(
    var.scripts_bucket_name,
    "bytecat-scripts-${data.aws_caller_identity.current.account_id}"
  )

  tags = merge(
    local.common_tags,
    {
      Name        = "${local.name_prefix}-scripts"
      Application = var.application_name
    }
  )
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  bucket = aws_s3_bucket.scripts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "data" {
  bucket = "bytecat-data-${var.application_name}-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    local.common_tags,
    {
      Name        = "Bytecat-Data-${var.application_name}"
      Application = var.application_name
    }
  )
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id

  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
# EFS
# -----------------------------------------------------------------------------

resource "aws_efs_file_system" "this" {
  encrypted       = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = merge(
    local.common_tags,
    {
      Name        = "Bytecat-EFS-${var.application_name}"
      Application = var.application_name
    }
  )
}

resource "aws_efs_mount_target" "this" {
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = var.private_subnet_id
  security_groups = [var.efs_security_group_id]
}

# -----------------------------------------------------------------------------
# IAM ROLE AND INSTANCE PROFILE
# -----------------------------------------------------------------------------

resource "aws_iam_role" "private_instance" {
  name_prefix = "Bytecat-${var.application_name}-Role-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name        = "Bytecat-${var.application_name}-Role"
      Application = var.application_name
    }
  )
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.private_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "s3_access" {
  name_prefix = "Bytecat-${var.application_name}-S3-Access-"
  role = aws_iam_role.private_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.scripts.arn,
          "${aws_s3_bucket.scripts.arn}/*",
          aws_s3_bucket.data.arn,
          "${aws_s3_bucket.data.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "route53_access" {
  name_prefix = "Bytecat-${var.application_name}-Route53-Access-"
  role = aws_iam_role.private_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:GetHostedZone",
          "route53:ListResourceRecordSets"
        ]
        Resource = [
          "arn:aws:route53:::hostedzone/${var.private_hosted_zone_id}"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_access" {
  name_prefix = "Bytecat-${var.application_name}-BedRock-Sonnet4-Access-"
  role = aws_iam_role.private_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:eu-west-1:886047113001:inference-profile/eu.anthropic.claude-sonnet-4-20250514-v1:0",
          "arn:aws:bedrock:eu-central-1::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0",
          "arn:aws:bedrock:eu-north-1::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0",
          "arn:aws:bedrock:eu-south-1::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0",
          "arn:aws:bedrock:eu-south-2::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0",
          "arn:aws:bedrock:eu-west-1::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0",
          "arn:aws:bedrock:eu-west-3::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecr_access" {
  name_prefix = "Bytecat-${var.application_name}-ECR-Access-"
  role = aws_iam_role.private_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages"
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/bytecat-*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "private_instance" {
  name_prefix = "Bytecat-${var.application_name}-Role-InstanceProfile-"
  role = aws_iam_role.private_instance.name

  tags = merge(
    local.common_tags,
    {
      Name        = "Bytecat-${var.application_name}-InstanceProfile"
      Application = var.application_name
    }
  )
}

# -----------------------------------------------------------------------------
# EC2 INSTANCE
# -----------------------------------------------------------------------------

resource "aws_instance" "private" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.private_subnet_id
  private_ip                  = var.private_instance_ip
  vpc_security_group_ids      = [var.private_instance_security_group_id]
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.private_instance.name
  associate_public_ip_address = false

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    application_name      = var.application_name
    domain_name           = var.domain_name
    private_hosted_zone_id = var.private_hosted_zone_id
    scripts_bucket_name   = aws_s3_bucket.scripts.bucket
    data_bucket_name      = aws_s3_bucket.data.bucket
    efs_filesystem_id     = aws_efs_file_system.this.id
    vpn_nat_private_ip    = var.vpn_nat_private_ip
    aws_region            = var.aws_region
  })

  tags = merge(
    local.common_tags,
    {
      Name        = "Bytecat-${var.application_name}"
      Application = var.application_name
    }
  )

  depends_on = [
    aws_s3_bucket_public_access_block.scripts,
    aws_s3_bucket_public_access_block.data,
    aws_efs_mount_target.this,
    aws_iam_role_policy.s3_access,
    aws_iam_role_policy.route53_access,
    aws_iam_role_policy.bedrock_access,
    aws_iam_role_policy.ecr_access
  ]
}
