output "scripts_bucket_name" {
  description = "Name of the S3 bucket that stores initialization scripts."
  value       = aws_s3_bucket.scripts.bucket
}

output "data_bucket_name" {
  description = "Name of the S3 bucket used for application data."
  value       = aws_s3_bucket.data.bucket
}

output "efs_filesystem_id" {
  description = "ID of the EFS file system."
  value       = aws_efs_file_system.this.id
}

output "private_instance_id" {
  description = "ID of the private application EC2 instance."
  value       = aws_instance.private.id
}

output "private_instance_private_ip" {
  description = "Private IP address of the application EC2 instance."
  value       = aws_instance.private.private_ip
}

