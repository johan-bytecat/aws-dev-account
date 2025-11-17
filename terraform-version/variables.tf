variable "aws_region" {
  description = "AWS region to deploy resources into."
  type        = string
}

variable "tag_name" {
  description = "Mandatory tag key applied to all taggable resources (e.g. CostCenter, Environment)."
  type        = string
}

variable "tag_value" {
  description = "Mandatory tag value applied to all taggable resources."
  type        = string
}

variable "application_name" {
  description = "Application name used for naming resources."
  type        = string
  default     = "kite-server"
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair for SSH access."
  type        = string
}

variable "private_subnet_id" {
  description = "ID of the private subnet where the application instance and EFS mount target will be created."
  type        = string
}

variable "private_instance_security_group_id" {
  description = "Security group ID to attach to the private application instance."
  type        = string
}

variable "efs_security_group_id" {
  description = "Security group ID to attach to the EFS mount target."
  type        = string
}

variable "private_instance_ip" {
  description = "Fixed private IP address for the application instance."
  type        = string
  default     = "172.16.2.100"
}

variable "domain_name" {
  description = "DNS domain name for the application (e.g. devcloud.bytecat.co.za)."
  type        = string
}

variable "private_hosted_zone_id" {
  description = "Route 53 private hosted zone ID where application records will be managed."
  type        = string
}

variable "vpn_nat_private_ip" {
  description = "Private IP address of the VPN/NAT instance used by the private subnet."
  type        = string
}

variable "scripts_bucket_name" {
  description = "Optional override for the scripts S3 bucket name. Defaults to devcloud-scripts-<account-id>."
  type        = string
  default     = ""
}

variable "ami_id" {
  description = "AMI ID for the application EC2 instance (Amazon Linux 2023 recommended)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the application server."
  type        = string
  default     = "t3.small"
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GiB."
  type        = number
  default     = 20
}
