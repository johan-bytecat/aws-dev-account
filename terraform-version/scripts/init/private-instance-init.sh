#!/bin/bash

# Private Instance Initialization Script
# Reads configuration from /opt/devcloud/config/init-parameters.env

# Set up logging
INIT_LOG="/var/log/private-instance-init.log"
exec > >(tee -a "$INIT_LOG") 2>&1

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "=== Private Instance Initialization Script Started ==="
log "Script PID: $$"
log "Working Directory: $(pwd)"
log "User: $(whoami)"

# Load configuration from environment file
CONFIG_FILE="/opt/devcloud/config/init-parameters.env"
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

log "Loading configuration from: $CONFIG_FILE"
source "$CONFIG_FILE"

# Map environment variables to script variables
HOSTED_ZONE_ID="$PRIVATE_HOSTED_ZONE_ID"
DOMAIN_NAME="$DOMAIN_NAME"
SCRIPTS_BUCKET="$SCRIPTS_BUCKET"
DATA_BUCKET="$DATA_BUCKET"
EFS_FILE_SYSTEM_ID="$EFS_FILESYSTEM_ID"

log "Configuration loaded:"
log "Hosted Zone: $HOSTED_ZONE_ID"
log "Domain: $DOMAIN_NAME"
log "Scripts Bucket: $SCRIPTS_BUCKET"
log "Data Bucket: $DATA_BUCKET"
log "EFS File System: $EFS_FILE_SYSTEM_ID"

# Validate required parameters
if [ -z "$HOSTED_ZONE_ID" ] || [ -z "$DOMAIN_NAME" ] || [ -z "$SCRIPTS_BUCKET" ] || [ -z "$DATA_BUCKET" ] || [ -z "$EFS_FILE_SYSTEM_ID" ]; then
    log "ERROR: Missing required parameters in configuration file"
    log "Required: PRIVATE_HOSTED_ZONE_ID, DOMAIN_NAME, SCRIPTS_BUCKET, DATA_BUCKET, EFS_FILESYSTEM_ID"
    exit 1
fi

# Install required packages
log "Installing required packages..."
if yum install -y docker amazon-efs-utils; then
    log "✓ Successfully installed docker and amazon-efs-utils"
else
    log "✗ Failed to install required packages"
    exit 1
fi

# Enable and start docker
log "Enabling docker service..."
if systemctl enable docker && systemctl start docker; then
    log "✓ Docker service enabled and started successfully"
else
    log "✗ Failed to enable docker service"
fi

# Create mount point and mount EFS
log "Setting up EFS mount..."
mkdir -p /mnt/data
log "Created mount point /mnt/data"

log "Adding EFS to /etc/fstab..."
echo "$EFS_FILE_SYSTEM_ID.efs.af-south-1.amazonaws.com:/ /mnt/data efs defaults,_netdev" >> /etc/fstab
log "EFS entry added to fstab"

log "Attempting to mount EFS..."
if mount -a; then
    log "✓ Mount command executed successfully"
else
    log "✗ Mount command failed"
fi

# Verify EFS mount
log "Verifying EFS mount..."
if mountpoint -q /mnt/data; then
    log "✓ EFS mounted successfully at /mnt/data"
    chown ec2-user:ec2-user /mnt/data
    log "✓ Changed ownership of /mnt/data to ec2-user"
else
    log "✗ WARNING: EFS mount failed - /mnt/data is not a mountpoint"
    log "Mount output:"
    mount | grep /mnt/data || log "No mount entries found for /mnt/data"
    log "Filesystem check:"
    df -h /mnt/data || log "df command failed for /mnt/data"
fi

# Set hostname
log "Setting hostname to kite.$DOMAIN_NAME..."
if hostnamectl set-hostname kite.$DOMAIN_NAME; then
    log "✓ Hostname set successfully"
else
    log "✗ Failed to set hostname"
fi

# Update Route53 DNS record with private IP
log "Updating DNS record for kite.$DOMAIN_NAME..."
log "Getting private IP from metadata service (IMDSv2)..."

# Get IMDSv2 token
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
if [ -z "$TOKEN" ]; then
    log "✗ Failed to retrieve IMDSv2 token"
    exit 1
fi

# Get private IP using the token
PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4)
if [ -n "$PRIVATE_IP" ] && [[ $PRIVATE_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "✓ Retrieved private IP: $PRIVATE_IP"
else
    log "✗ Failed to retrieve valid private IP: '$PRIVATE_IP'"
    exit 1
fi

log "Updating Route53 DNS record..."
if aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"kite.$DOMAIN_NAME.\",
        \"Type\": \"A\",
        \"TTL\": 60,
        \"ResourceRecords\": [{ \"Value\": \"$PRIVATE_IP\" }]
      }
    }]
  }"; then
    log "✓ DNS record updated successfully: kite.$DOMAIN_NAME -> $PRIVATE_IP"
else
    log "✗ Failed to update DNS record"
    exit 1
fi

# Create directories for applications
mkdir -p /opt/applications
mkdir -p /var/log/applications
chown ec2-user:ec2-user /opt/applications
chown ec2-user:ec2-user /var/log/applications

# Download and execute any additional setup scripts
if aws s3 ls s3://$SCRIPTS_BUCKET/private-instance/ >/dev/null 2>&1; then
    echo "Downloading additional private instance configuration scripts..."
    mkdir -p /opt/devcloud/private-instance
    aws s3 sync s3://$SCRIPTS_BUCKET/private-instance/ /opt/devcloud/private-instance/
    chmod +x /opt/devcloud/private-instance/*.sh
    
    # Create symbolic links in /usr/local/bin for scripts that expect to be there
    mkdir -p /usr/local/bin/private-scripts
    for script in /opt/devcloud/private-instance/*.sh; do
        if [ -f "$script" ]; then
            script_name=$(basename "$script")
            ln -sf "$script" "/usr/local/bin/private-scripts/$script_name"
        fi
    done
    
    # Execute any setup scripts
    for script in /opt/devcloud/private-instance/setup-*.sh; do
        if [ -f "$script" ]; then
            echo "Executing setup script: $script"
            bash "$script" "$SCRIPTS_BUCKET" "$DATA_BUCKET"
        fi
    done
    
    # Install DNS update service if available
    if [ -f "/opt/devcloud/private-instance/update-dns-on-boot.sh" ]; then
        echo "Installing DNS update service..."
        ln -sf /opt/devcloud/private-instance/update-dns-on-boot.sh /usr/local/bin/update-dns-on-boot.sh
        
        # Install systemd service if available
        if [ -f "/opt/devcloud/private-instance/dns-update.service" ]; then
            cp /opt/devcloud/private-instance/dns-update.service /etc/systemd/system/dns-update.service
            systemctl daemon-reload
            systemctl enable dns-update.service
            echo "DNS update service installed and enabled"
        fi
    fi
fi

# Create a simple health check script in /opt/devcloud and symlink to /usr/local/bin
mkdir -p /opt/devcloud/bin
cat > /opt/devcloud/bin/health-check.sh << EOF
#!/bin/bash
# Health check script for private instance

echo "=== Health Check Report ===" > /tmp/health-check.log
echo "Date: \$(date)" >> /tmp/health-check.log
echo "Hostname: \$(hostname)" >> /tmp/health-check.log
echo "Uptime: \$(uptime)" >> /tmp/health-check.log
echo "Disk Usage:" >> /tmp/health-check.log
df -h >> /tmp/health-check.log
echo "EFS Mount Status:" >> /tmp/health-check.log
mountpoint /mnt/data && echo "EFS mounted OK" >> /tmp/health-check.log || echo "EFS mount FAILED" >> /tmp/health-check.log
echo "Docker Status:" >> /tmp/health-check.log
systemctl is-active docker >> /tmp/health-check.log

# Upload health check to S3
aws s3 cp /tmp/health-check.log s3://$DATA_BUCKET/health-checks/\$(hostname)-\$(date +%Y%m%d-%H%M%S).log
EOF

chmod +x /opt/devcloud/bin/health-check.sh

# Create symbolic link for backward compatibility
ln -sf /opt/devcloud/bin/health-check.sh /usr/local/bin/health-check.sh

# Set up a cron job for health checks (every 6 hours)
echo "0 */6 * * * /usr/local/bin/health-check.sh" | crontab -u ec2-user -

# Configure log rotation for application logs
cat > /etc/logrotate.d/applications << EOF
/var/log/applications/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 ec2-user ec2-user
    postrotate
        # Upload rotated logs to S3
        find /var/log/applications -name "*.gz" -mtime -1 -exec aws s3 cp {} s3://$DATA_BUCKET/logs/ \;
    endscript
}
EOF

echo "Private Instance initialization completed successfully!"

# Log completion
log "=== Private Instance Initialization Completed Successfully ==="
log "Timestamp: $(date)"
log "Total script execution time: $SECONDS seconds"
log "Log files:"
log "  - Initialization: $INIT_LOG"
log "  - General: /var/log/initialization.log"
log "============================================================"

echo "$(date): Private Instance initialization completed" >> /var/log/initialization.log

# Run initial health check
log "Running initial health check..."
/usr/local/bin/health-check.sh
