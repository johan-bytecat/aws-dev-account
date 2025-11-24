terraform {
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

data "aws_subnet" "private" {
  id = var.private_subnet_id
}

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
    length(var.scripts_bucket_name) > 0 ? var.scripts_bucket_name : null,
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
  encrypted        = true
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
  security_groups = [aws_security_group.efs.id]
}

# -----------------------------------------------------------------------------
# IAM ROLE, POLICIES, INSTANCE PROFILE
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

# -----------------------------------------------------------------------------
# SECURITY GROUPS
# -----------------------------------------------------------------------------

resource "aws_security_group" "private_instance" {
  name_prefix = "bytecat-${var.application_name}-instance-"
  description = "Security group for Bytecat private EC2 instance"
  vpc_id      = data.aws_subnet.private.vpc_id

  # Allow SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name        = "bytecat-${var.application_name}-instance-sg"
      Application = var.application_name
    }
  )
}

resource "aws_security_group" "efs" {
  name_prefix = "bytecat-${var.application_name}-efs-"
  description = "Security group for Bytecat EFS"
  vpc_id      = data.aws_subnet.private.vpc_id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.private_instance.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name        = "bytecat-${var.application_name}-efs-sg"
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
  role        = aws_iam_role.private_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.scripts.arn,
          "${aws_s3_bucket.scripts.arn}/*",
          aws_s3_bucket.data.arn,
          "${aws_s3_bucket.data.arn}/*",
          "arn:aws:s3:::bcd-569473826527836",
          "arn:aws:s3:::bcd-569473826527836/*"
        ]
      }
    ]
  })
}

# No Route53 policy in the simplified stack

resource "aws_iam_role_policy" "bedrock_access" {
  name_prefix = "Bytecat-${var.application_name}-BedRock-Sonnet4-Access-"
  role        = aws_iam_role.private_instance.id

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
          "arn:aws:bedrock:eu-west-3::foundation-model/anthropic-clause-sonnet-4-20250514-v1:0"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecr_access" {
  name_prefix = "Bytecat-${var.application_name}-ECR-Access-"
  role        = aws_iam_role.private_instance.id

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
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "arn:aws:ecr:af-south-1:886047113001:repository/bytecat-*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "private_instance" {
  name_prefix = "Bytecat-${var.application_name}-Role-InstanceProfile-"
  role        = aws_iam_role.private_instance.name

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
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_id
  private_ip             = var.private_instance_ip
  vpc_security_group_ids = [aws_security_group.private_instance.id]
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null
  iam_instance_profile   = aws_iam_instance_profile.private_instance.name

  associate_public_ip_address = false

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    application_name    = var.application_name
    data_bucket_name    = aws_s3_bucket.data.bucket
    scripts_bucket_name = aws_s3_bucket.scripts.bucket
    efs_filesystem_id   = aws_efs_file_system.this.id
    aws_region          = var.aws_region
    private_ip          = var.private_instance_ip
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
    aws_iam_role_policy.bedrock_access,
    aws_iam_role_policy.ecr_access
  ]
}

output "scripts_bucket_name" {
  value       = aws_s3_bucket.scripts.bucket
  description = "Name of the scripts S3 bucket"
}

output "data_bucket_name" {
  value       = aws_s3_bucket.data.bucket
  description = "Name of the data S3 bucket"
}

output "instance_private_ip" {
  value       = aws_instance.private.private_ip
  description = "Private IP address of the EC2 instance"
}

output "ec2_role_name" {
  value       = aws_iam_role.private_instance.name
  description = "Name of the IAM role attached to the EC2 instance"
}
