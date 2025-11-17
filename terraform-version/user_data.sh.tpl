#!/bin/bash

# Set up logging for userdata execution
exec > >(tee /var/log/user-data.log) 2>&1

echo "=== Bytecat ${application_name} Instance Initialization Started ==="
echo "Timestamp: $(date)"

# Create directories for scripts and parameters
mkdir -p /opt/devcloud/scripts
mkdir -p /opt/devcloud/config

# Save initialization parameters to file for future use
cat > /opt/devcloud/config/init-parameters.env << EOF
APPLICATION_NAME=${application_name}
PRIVATE_HOSTED_ZONE_ID=${private_hosted_zone_id}
DOMAIN_NAME=${domain_name}
SCRIPTS_BUCKET=${scripts_bucket_name}
DATA_BUCKET=${data_bucket_name}
EFS_FILESYSTEM_ID=${efs_filesystem_id}
VPN_NAT_PRIVATE_IP=${vpn_nat_private_ip}
EOF

# Get instance metadata using IMDSv2
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)
AMI_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/ami-id)
INSTANCE_TYPE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-type)

echo "Instance ID: $INSTANCE_ID"
echo "AMI ID: $AMI_ID"
echo "Instance Type: $INSTANCE_TYPE"
echo "Application: ${application_name}"
echo "=========================================================="

# Verify basic connectivity before proceeding
echo "Verifying basic connectivity..."
echo "Expected NAT Gateway IP: ${vpn_nat_private_ip}"

for i in {1..10}; do
  echo "Connectivity test attempt $i/10..."
  if curl -s --connect-timeout 5 http://169.254.169.254/latest/meta-data/instance-id > /dev/null; then
    echo "✓ Basic connectivity confirmed"
    break
  elif [ $i -eq 10 ]; then
    echo "✗ Failed to establish connectivity after 10 attempts"
    exit 1
  else
    echo "Retrying in 30 seconds..."
    sleep 30
  fi
done

# Update system packages
echo "Updating system packages..."
yum update -y

# Install EFS utilities
echo "Installing EFS utilities..."
yum install -y amazon-efs-utils

# Create EFS mount point
echo "Setting up EFS mount..."
mkdir -p /mnt/efs

# Mount EFS filesystem
echo "Mounting EFS filesystem: ${efs_filesystem_id}"
mount -t efs -o tls ${efs_filesystem_id}:/ /mnt/efs

# Add EFS mount to fstab for persistence
echo "${efs_filesystem_id}.efs.${aws_region}.amazonaws.com:/ /mnt/efs efs tls,_netdev" >> /etc/fstab

# Set proper permissions
chown ec2-user:ec2-user /mnt/efs

# Download and execute initialization script from S3
echo "Downloading initialization script from S3..."
echo "Scripts Bucket: ${scripts_bucket_name}"
echo "Data Bucket: ${data_bucket_name}"
echo "Private Hosted Zone: ${private_hosted_zone_id}"
echo "Domain Name: ${domain_name}"
echo "EFS File System: ${efs_filesystem_id}"

if aws s3 cp s3://${scripts_bucket_name}/init/private-instance-init.sh /opt/devcloud/scripts/private-instance-init.sh; then
  chmod +x /opt/devcloud/scripts/private-instance-init.sh
  echo "Executing initialization script..."
  if /opt/devcloud/scripts/private-instance-init.sh; then
    echo "✓ Private instance initialization completed successfully"
  else
    echo "✗ Private instance initialization failed with exit code $?"
    exit 1
  fi
else
  echo "✗ Failed to download private-instance-init.sh from S3"
  echo "Instance will continue without application-specific initialization"
fi

echo "=== Bytecat ${application_name} Instance Initialization Completed ==="
echo "Timestamp: $(date)"
echo "Parameters saved to: /opt/devcloud/config/init-parameters.env"
echo "Scripts stored in: /opt/devcloud/scripts/"
echo "EFS mounted at: /mnt/efs"
echo "Log file: /var/log/user-data.log"
echo "=========================================================="
