# DevCloud Application Terraform Module (OpenTofu Compatible)

This configuration recreates the **application** part of `02-application.yaml` using Terraform/OpenTofu. It creates:

- An S3 bucket for scripts.
- An S3 bucket for application data.
- An encrypted EFS file system and mount target.
- An IAM role and instance profile for the application EC2 instance.
- A private EC2 instance with user data that mounts EFS and pulls an init script from S3.

All taggable resources are tagged with the mandatory `tag_name` / `tag_value` pair you provide.

## Inputs (required)

- `aws_region` – AWS region to deploy into (e.g. `eu-west-1`).
- `tag_name` – Tag key to apply to all resources (e.g. `Environment`).
- `tag_value` – Tag value to apply to all resources (e.g. `dev`).
- `key_pair_name` – Existing EC2 key pair name for SSH.
- `private_subnet_id` – ID of the private subnet for the instance and EFS mount target.
- `private_instance_security_group_id` – Security group ID for the EC2 instance.
- `efs_security_group_id` – Security group ID for the EFS mount target.
- `domain_name` – DNS domain (e.g. `bytecat.co.za`).
- `private_hosted_zone_id` – Route 53 private hosted zone ID.
- `vpn_nat_private_ip` – Private IP of the NAT/VPN instance used by this subnet.
- `ami_id` – AMI ID for the EC2 instance (Amazon Linux 2023 recommended).

Optional inputs:

- `application_name` – Defaults to `kite-server`.
- `private_instance_ip` – Defaults to `172.16.2.100`.
- `scripts_bucket_name` – Optional custom scripts bucket name; if not set, defaults to `bytecat-scripts-<account-id>`.
- `instance_type` – Defaults to `t3.small`.
- `root_volume_size` – Defaults to `20` (GiB).

## Usage

From the `terraform-version` directory:

1. Initialize:
   - `terraform init` **or** `tofu init`

2. First apply to create the buckets and IAM so you can upload scripts before the EC2 instance starts:
   - `terraform apply -target=aws_s3_bucket.scripts -target=aws_s3_bucket.data`  
     (or the equivalent `tofu apply` command)

3. Upload your initialization script to S3:
   - Upload `private-instance-init.sh` to `s3://<scripts-bucket-name>/init/private-instance-init.sh`.
   - The scripts bucket name is available via the `scripts_bucket_name` output.

4. Apply the full stack to create EFS and the EC2 instance:
   - `terraform apply` (or `tofu apply`)

The EC2 user data will:

- Log to `/var/log/user-data.log`.
- Write initialization parameters to `/opt/devcloud/config/init-parameters.env`.
- Install `amazon-efs-utils`, mount EFS at `/mnt/efs`, and persist it via `/etc/fstab`.
- Download and execute `/opt/devcloud/scripts/private-instance-init.sh` from the scripts S3 bucket.
