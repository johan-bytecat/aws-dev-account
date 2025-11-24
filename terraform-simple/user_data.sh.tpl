#!/bin/bash

# Set up logging for userdata execution
exec > >(tee /var/log/user-data.log) 2>&1

echo "=== Bytecat ${application_name} Instance Initialization Started ==="
echo "Timestamp: $(date)"

# Create directories for config and data
mkdir -p /opt/bytecat/config
mkdir -p /data

# Save initialization parameters
cat > /opt/bytecat/config/init-parameters.env << EOF
APPLICATION_NAME=${application_name}
SCRIPTS_BUCKET=${scripts_bucket_name}
DATA_BUCKET=${data_bucket_name}
PRIVATE_IP=${private_ip}
EOF

# Update system packages
echo "Updating system packages..."
yum update -y

# Install EFS utilities
echo "Installing EFS utilities..."
yum install -y amazon-efs-utils

# Mount EFS at /data
echo "Setting up EFS mount at /data..."
mount -t efs -o tls ${efs_filesystem_id}:/ /data
echo "${efs_filesystem_id}.efs.${aws_region}.amazonaws.com:/ /data efs tls,_netdev" >> /etc/fstab
chown ec2-user:ec2-user /data

# Install Docker
echo "Installing Docker..."
yum install -y docker
systemctl enable docker
systemctl start docker

# Install Docker Compose (v2 as standalone binary)
echo "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/download/v2.30.0/docker-compose-linux-x86_64" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

echo "Docker version:"
docker --version || true
echo "Docker Compose version:"
docker-compose --version || true

echo "=== Bytecat ${application_name} Instance Initialization Completed ==="
echo "Timestamp: $(date)"
echo "Parameters saved to: /opt/bytecat/config/init-parameters.env"
echo "EFS mounted at: /data"
echo "Log file: /var/log/user-data.log"
