variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default	  = "af-south-1"
}

variable "application_name" {
  description = "Application name used for tagging/naming"
  type        = string
  default     = "kite-server"
}

variable "tag_name" {
  description = "Tag key for common tags"
  type        = string
  default     = "ByteCatTag"
}

variable "tag_value" {
  description = "Tag value for common tags"
  type        = string
  default     = "ByteCatTagValue"
}

variable "private_subnet_id" {
  description = "Private subnet ID for the EC2 instance and EFS mount target"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the EC2 instance (e.g. Amazon Linux 2023)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "key_pair_name" {
  description = "Existing EC2 key pair name"
  type        = string
  default     = ""
}

variable "private_instance_ip" {
  description = "Static private IP for the EC2 instance (must be free in the subnet)"
  type        = string
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB"
  type        = number
  default     = 20
}

variable "scripts_bucket_name" {
  description = "Optional pre-defined scripts bucket name; if empty a new one is created"
  type        = string
  default     = ""
}
