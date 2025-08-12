#!/bin/bash

# VPN/NAT Gateway Initialization Script
# Reads configuration from /opt/devcloud/config/init-parameters.env

# Set up logging
INIT_LOG="/var/log/vpn-nat-init.log"
exec > >(tee -a "$INIT_LOG") 2>&1

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "=== VPN/NAT Gateway Initialization Script Started ==="
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
HOSTED_ZONE_ID="$PUBLIC_HOSTED_ZONE_ID"
DOMAIN_NAME="$DOMAIN_NAME"
SCRIPTS_BUCKET="$SCRIPTS_BUCKET"

log "Configuration loaded:"
log "Hosted Zone: $HOSTED_ZONE_ID"
log "Domain: $DOMAIN_NAME"
log "Scripts Bucket: $SCRIPTS_BUCKET"

# Validate required parameters
if [ -z "$HOSTED_ZONE_ID" ] || [ -z "$DOMAIN_NAME" ] || [ -z "$SCRIPTS_BUCKET" ]; then
    log "ERROR: Missing required parameters in configuration file"
    log "Required: PUBLIC_HOSTED_ZONE_ID, DOMAIN_NAME, SCRIPTS_BUCKET"
    exit 1
fi

# Download scripts first before any installation or configuration
log "Downloading VPN/NAT configuration scripts..."
if aws s3 ls s3://$SCRIPTS_BUCKET/vpn-nat/ >/dev/null 2>&1; then
    log "Downloading VPN/NAT scripts from S3..."
    mkdir -p /opt/devcloud/vpn-nat
    aws s3 sync s3://$SCRIPTS_BUCKET/vpn-nat/ /opt/devcloud/vpn-nat/
    chmod +x /opt/devcloud/vpn-nat/*.sh
    
    # Create symbolic links in /usr/local/bin for scripts that expect to be there
    mkdir -p /usr/local/bin/vpn-scripts
    for script in /opt/devcloud/vpn-nat/*.sh; do
        if [ -f "$script" ]; then
            script_name=$(basename "$script")
            ln -sf "$script" "/usr/local/bin/vpn-scripts/$script_name"
        fi
    done
    
    log "✓ VPN/NAT scripts downloaded and installed"
else
    log "Warning: No VPN/NAT scripts found in S3 bucket"
fi

# Install required packages
log "Installing required packages..."
if yum install -y wireguard-tools iptables-services; then
    log "✓ Successfully installed wireguard-tools and iptables-services"
else
    log "✗ Failed to install required packages"
    exit 1
fi

# Enable iptables service
log "Enabling iptables service..."
systemctl enable iptables
if systemctl start iptables; then
    log "✓ iptables service started successfully"
else
    log "✗ Failed to start iptables service"
    exit 1
fi

# Enable IP forwarding
log "Enabling IP forwarding..."
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
if sysctl -p; then
    log "✓ IP forwarding enabled successfully"
else
    log "✗ Failed to enable IP forwarding"
    exit 1
fi

# Configure WireGuard
cd /etc/wireguard

# Check if WireGuard configuration exists in S3
if aws s3 ls s3://$SCRIPTS_BUCKET/wireguard/server-private.key >/dev/null 2>&1; then
    echo "Found existing WireGuard configuration in S3"
    aws s3 cp s3://$SCRIPTS_BUCKET/wireguard/server-private.key /etc/wireguard/privatekey
    aws s3 cp s3://$SCRIPTS_BUCKET/wireguard/server-public.key /etc/wireguard/publickey
    aws s3 cp s3://$SCRIPTS_BUCKET/wireguard/wg0.conf /etc/wireguard/wg0.conf
else
    echo "Generating new WireGuard keys"
    wg genkey | tee privatekey | wg pubkey > publickey
    
    # Upload keys to S3 for persistence
    aws s3 cp privatekey s3://$SCRIPTS_BUCKET/wireguard/server-private.key
    aws s3 cp publickey s3://$SCRIPTS_BUCKET/wireguard/server-public.key
    
    # Create initial WireGuard configuration
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $(cat privatekey)
Address = 10.0.0.1/24
ListenPort = 51820

# Client configurations will be added here
EOF
    
    # Upload initial configuration to S3
    aws s3 cp /etc/wireguard/wg0.conf s3://$SCRIPTS_BUCKET/wireguard/wg0.conf
fi

# Set proper permissions
chmod 600 /etc/wireguard/privatekey
chmod 644 /etc/wireguard/publickey
chmod 600 /etc/wireguard/wg0.conf

# Enable and start WireGuard
log "Enabling WireGuard service..."
systemctl enable wg-quick@wg0
log "Starting WireGuard service..."
if systemctl start wg-quick@wg0; then
    log "✓ WireGuard service started successfully"
else
    log "✗ Failed to start WireGuard service"
    log "Checking WireGuard service status..."
    systemctl status wg-quick@wg0 --no-pager -l
    exit 1
fi

# Create default client if it doesn't exist
log "Checking for default client configuration..."
if ! aws s3 ls s3://$SCRIPTS_BUCKET/wireguard/default/ >/dev/null 2>&1; then
    log "Creating default client configuration..."
    
    # Use the downloaded add-wireguard-client.sh script
    if [ ! -f "/opt/devcloud/vpn-nat/add-wireguard-client.sh" ]; then
        log "✗ ERROR: add-wireguard-client.sh script not found at /opt/devcloud/vpn-nat/"
        log "✗ Cannot create default client without the proper script"
        exit 1
    fi
    
    log "Using add-wireguard-client.sh script to create default client"
    if /opt/devcloud/vpn-nat/add-wireguard-client.sh default; then
        log "✓ Default client created successfully"
    else
        log "✗ Failed to create default client using add-wireguard-client.sh"
        exit 1
    fi
else
    log "✓ Default client already exists"
fi

# Update Route53 DNS record with public IP
log "Updating DNS record for access.$DOMAIN_NAME..."
log "Getting public IP from metadata service (IMDSv2)..."

# Get IMDSv2 token
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
if [ -z "$TOKEN" ]; then
    log "✗ Failed to retrieve IMDSv2 token"
    exit 1
fi

# Get public IP using the token
PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/public-ipv4)
if [ -n "$PUBLIC_IP" ] && [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "✓ Retrieved public IP: $PUBLIC_IP"
else
    log "✗ Failed to retrieve valid public IP: '$PUBLIC_IP'"
    exit 1
fi

log "Updating Route53 DNS record..."
if aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"access.$DOMAIN_NAME.\",
        \"Type\": \"A\",
        \"TTL\": 60,
        \"ResourceRecords\": [{ \"Value\": \"$PUBLIC_IP\" }]
      }
    }]
  }"; then
    log "✓ DNS record updated successfully: access.$DOMAIN_NAME -> $PUBLIC_IP"
else
    log "✗ Failed to update DNS record"
    exit 1
fi

# Configure NAT functionality and iptables security
log "Configuring comprehensive iptables rules..."

# Run the downloaded iptables configuration script
if [ -f "/opt/devcloud/vpn-nat/configure-iptables.sh" ]; then
    log "Running iptables configuration script..."
    if /opt/devcloud/vpn-nat/configure-iptables.sh; then
        log "✓ iptables configuration completed successfully"
    else
        log "✗ iptables configuration failed"
        exit 1
    fi
else
    log "✗ iptables configuration script not found at /opt/devcloud/vpn-nat/configure-iptables.sh"
    exit 1
fi

# Download any additional configuration scripts
if aws s3 ls s3://$SCRIPTS_BUCKET/vpn-nat/ >/dev/null 2>&1; then
    # Install DNS update service if available (scripts already downloaded earlier)
    if [ -f "/opt/devcloud/vpn-nat/update-dns-on-boot.sh" ]; then
        log "Installing DNS update service..."
        ln -sf /opt/devcloud/vpn-nat/update-dns-on-boot.sh /usr/local/bin/update-dns-on-boot.sh
        
        # Install systemd service if available
        if [ -f "/opt/devcloud/vpn-nat/dns-update.service" ]; then
            cp /opt/devcloud/vpn-nat/dns-update.service /etc/systemd/system/dns-update.service
            systemctl daemon-reload
            systemctl enable dns-update.service
            log "DNS update service installed and enabled"
        fi
    fi
fi

log "VPN/NAT Gateway initialization completed successfully!"

# Log completion
log "=== VPN/NAT Gateway Initialization Completed Successfully ==="
log "Timestamp: $(date)"
log "Total script execution time: $SECONDS seconds"
log "Scripts available in: /opt/devcloud/vpn-nat/"
log "Create additional clients with: sudo /opt/devcloud/vpn-nat/add-wireguard-client.sh <client_name>"
log "Log files:"
log "  - Initialization: $INIT_LOG"
log "  - General: /var/log/initialization.log"
log "=============================================================="

echo "$(date): VPN/NAT Gateway initialization completed" >> /var/log/initialization.log
