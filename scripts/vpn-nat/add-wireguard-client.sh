#!/bin/bash

# Server-side script to add WireGuard clients (S3-backed configuration)
# Run this on the VPN/NAT Gateway instance
# Usage: sudo ./add-wireguard-client.sh <client_name>

CLIENT_NAME="$1"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    echo "Usage: sudo $0 <client_name>"
    exit 1
fi

if [ -z "$CLIENT_NAME" ]; then
    echo "Usage: sudo $0 <client_name>"
    echo "Example: sudo $0 laptop"
    echo "This script will:"
    echo "  - Generate client private/public keys"
    echo "  - Create complete client configuration"
    echo "  - Upload config to S3 for download (if permissions allow)"
    exit 1
fi

# Get the scripts bucket name from the CloudFormation stack
# Try multiple methods since IAM permissions may be limited
SCRIPTS_BUCKET=""

# Method 1: Try CloudFormation (may fail due to permissions)
SCRIPTS_BUCKET=$(aws cloudformation describe-stacks --stack-name devcloud-foundation --region af-south-1 --query 'Stacks[0].Outputs[?OutputKey==`ScriptsBucketName`].OutputValue' --output text 2>/dev/null)

# Method 2: Use the known bucket name pattern if CloudFormation fails
if [ -z "$SCRIPTS_BUCKET" ] || [ "$SCRIPTS_BUCKET" = "None" ]; then
    echo "Warning: CloudFormation access denied, using default bucket name pattern"
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -n "$ACCOUNT_ID" ]; then
        SCRIPTS_BUCKET="devcloud-scripts-$ACCOUNT_ID"
    else
        SCRIPTS_BUCKET="devcloud-scripts-886047113001"
    fi
fi

if [ -z "$SCRIPTS_BUCKET" ]; then
    echo "Error: Could not determine scripts bucket name"
    exit 1
fi

# Check if client already exists
if aws s3 ls s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/ >/dev/null 2>&1; then
    echo "Error: Client '$CLIENT_NAME' already exists"
    echo "Client configurations:"
    aws s3 ls s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/
    exit 1
fi

echo "Creating WireGuard client: $CLIENT_NAME"
echo "Scripts bucket: $SCRIPTS_BUCKET"

# Ensure WireGuard directory exists
mkdir -p /etc/wireguard

# Download current server configuration from S3 or create initial one
if aws s3 cp s3://$SCRIPTS_BUCKET/wireguard/wg0.conf /tmp/wg0.conf.current 2>/dev/null; then
    echo "Downloaded existing server configuration from S3"
elif [ -f /etc/wireguard/wg0.conf ]; then
    echo "Using existing local server configuration"
    cp /etc/wireguard/wg0.conf /tmp/wg0.conf.current
else
    echo "No existing server configuration found, creating initial configuration"
    # Create basic server configuration
    cat > /tmp/wg0.conf.current << EOF
# WireGuard Server Configuration
# Generated on $(date)

[Interface]
PrivateKey = $(cat /etc/wireguard/privatekey 2>/dev/null || wg genkey | tee /etc/wireguard/privatekey)
Address = 10.0.0.1/24
ListenPort = 51820
SaveConfig = false

# Enable IP forwarding and NAT
PostUp = echo 1 > /proc/sys/net/ipv4/ip_forward
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -d 172.16.0.0/16 -j MASQUERADE

PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -d 172.16.0.0/16 -j MASQUERADE

EOF
    # Generate server keys if they don't exist
    if [ ! -f /etc/wireguard/privatekey ]; then
        wg genkey > /etc/wireguard/privatekey
        chmod 600 /etc/wireguard/privatekey
    fi
    if [ ! -f /etc/wireguard/publickey ]; then
        cat /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
    fi
fi

# Get next available IP
LAST_IP=$(grep -o '10\.0\.0\.[0-9]*' /tmp/wg0.conf.current | tail -1 | cut -d. -f4 2>/dev/null)
if [ -z "$LAST_IP" ]; then
    NEXT_IP=2
else
    NEXT_IP=$((LAST_IP + 1))
fi

CLIENT_IP="10.0.0.$NEXT_IP"

echo "Assigning client IP: $CLIENT_IP"

# Generate client keys
echo "Generating client keys..."
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

echo "Client public key: $CLIENT_PUBLIC_KEY"

# Create client directory structure
mkdir -p /tmp/client-$CLIENT_NAME

# Store client keys
echo "$CLIENT_PRIVATE_KEY" > /tmp/client-$CLIENT_NAME/private.key
echo "$CLIENT_PUBLIC_KEY" > /tmp/client-$CLIENT_NAME/public.key

# Get server public key and endpoint
SERVER_PUBLIC_KEY=$(cat /etc/wireguard/publickey 2>/dev/null)
if [ -z "$SERVER_PUBLIC_KEY" ]; then
    echo "Warning: Could not read server public key, generating new one"
    if [ ! -f /etc/wireguard/privatekey ]; then
        wg genkey > /etc/wireguard/privatekey
        chmod 600 /etc/wireguard/privatekey
    fi
    SERVER_PUBLIC_KEY=$(cat /etc/wireguard/privatekey | wg pubkey | tee /etc/wireguard/publickey)
fi

# Create complete client configuration
cat > /tmp/client-$CLIENT_NAME/$CLIENT_NAME.conf << EOF
# WireGuard Client Configuration for $CLIENT_NAME
# Generated on $(date)
# 
# Install instructions:
# 1. Install WireGuard on your device
# 2. Import this configuration file
# 3. Connect to the VPN
#
# Split tunneling is enabled - only VPC traffic routes through VPN

[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/32
DNS = 172.16.0.2

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = access.devcloud.bytecat.co.za:51820
AllowedIPs = 172.16.0.0/16, 10.0.0.0/24
PersistentKeepalive = 25

# Configuration Details:
# - Client IP: $CLIENT_IP
# - VPN Network: 10.0.0.0/24
# - VPC Network: 172.16.0.0/16 (routed through VPN)
# - DNS: 172.16.0.2 (VPC DNS resolver)
# - AllowedIPs: VPC (172.16.0.0/16) + VPN clients (10.0.0.0/24)
# - All other traffic uses your local internet connection
EOF

# Create installation instructions
cat > /tmp/client-$CLIENT_NAME/README.txt << EOF
WireGuard Client Setup Instructions for $CLIENT_NAME
==================================================

Generated: $(date)
Client IP: $CLIENT_IP

Installation Steps:
==================

Windows:
--------
1. Download WireGuard from: https://www.wireguard.com/install/
2. Install and open WireGuard
3. Click "Add Tunnel" > "Add from file"
4. Select the $CLIENT_NAME.conf file
5. Click "Activate" to connect

macOS:
------
1. Install WireGuard from App Store
2. Click "+" > "Add from file"
3. Select the $CLIENT_NAME.conf file
4. Toggle the connection on

Linux:
------
1. Install WireGuard: sudo apt install wireguard (Ubuntu/Debian)
2. Copy $CLIENT_NAME.conf to /etc/wireguard/
3. Start: sudo wg-quick up $CLIENT_NAME
4. Stop: sudo wg-quick down $CLIENT_NAME

Mobile (iOS/Android):
--------------------
1. Install WireGuard app from App/Play Store
2. Tap "+" > "Create from file or archive"
3. Select the $CLIENT_NAME.conf file
4. Tap to connect

Verification:
=============
Once connected:
- Visit http://kite.devcloud.bytecat.co.za (should work)
- Check your IP: curl ifconfig.me (should NOT be VPN IP)
- VPN routes VPC (172.16.0.0/16) and VPN clients (10.0.0.0/24)
- Ping other VPN clients: ping 10.0.0.X (if other clients exist)

Troubleshooting:
===============
- Ensure only one WireGuard connection is active at a time
- Check endpoint is reachable: ping access.devcloud.bytecat.co.za
- Verify port 51820/UDP is not blocked by your firewall

Configuration Details:
=====================
- Server: access.devcloud.bytecat.co.za:51820
- Client IP: $CLIENT_IP/32
- Split tunneling: Enabled (VPC + VPN clients only)
- AllowedIPs: 172.16.0.0/16 (VPC) + 10.0.0.0/24 (VPN clients)
- DNS: 172.16.0.2 (for .devcloud.bytecat.co.za resolution)
EOF

# Upload client configuration to S3
echo "Uploading client configuration to S3..."
S3_UPLOAD_SUCCESS=true

# Try to upload files, but don't fail if S3 permissions are missing
if ! aws s3 cp /tmp/client-$CLIENT_NAME/$CLIENT_NAME.conf s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/$CLIENT_NAME.conf 2>/dev/null; then
    echo "Warning: Could not upload configuration to S3 (permission denied)"
    S3_UPLOAD_SUCCESS=false
fi

if ! aws s3 cp /tmp/client-$CLIENT_NAME/README.txt s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/README.txt 2>/dev/null; then
    echo "Warning: Could not upload README to S3 (permission denied)"
fi

if ! aws s3 cp /tmp/client-$CLIENT_NAME/private.key s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/private.key 2>/dev/null; then
    echo "Warning: Could not upload private key to S3 (permission denied)"
fi

if ! aws s3 cp /tmp/client-$CLIENT_NAME/public.key s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/public.key 2>/dev/null; then
    echo "Warning: Could not upload public key to S3 (permission denied)"
fi

# Add client to server configuration
echo "Updating server configuration..."
cat >> /tmp/wg0.conf.current << EOF

# Client: $CLIENT_NAME (IP: $CLIENT_IP)
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32

EOF

# Update local server configuration
cp /tmp/wg0.conf.current /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# Upload updated server configuration to S3 (if permissions allow)
if ! aws s3 cp /etc/wireguard/wg0.conf s3://$SCRIPTS_BUCKET/wireguard/wg0.conf 2>/dev/null; then
    echo "Warning: Could not upload server configuration to S3 (permission denied)"
fi

# Restart WireGuard to apply changes
echo "Restarting WireGuard service..."
if systemctl restart wg-quick@wg0 2>/dev/null; then
    echo "✓ WireGuard service restarted successfully"
else
    echo "Warning: Could not restart WireGuard service automatically"
    echo "Please run: sudo systemctl restart wg-quick@wg0"
fi

echo ""
echo "✓ Client '$CLIENT_NAME' created successfully!"
echo ""

# Create local backup directory for manual distribution
LOCAL_BACKUP_DIR="/home/ec2-user/wireguard-clients/$CLIENT_NAME"
mkdir -p "$LOCAL_BACKUP_DIR"
cp /tmp/client-$CLIENT_NAME/* "$LOCAL_BACKUP_DIR/"
chown -R ec2-user:ec2-user "/home/ec2-user/wireguard-clients"

echo "Client files saved locally to: $LOCAL_BACKUP_DIR"
echo ""

if [ "$S3_UPLOAD_SUCCESS" = true ]; then
    echo "Download URLs:"
    echo "  Configuration: s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/$CLIENT_NAME.conf"
    echo "  Instructions:  s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/README.txt"
    echo ""
    echo "Download commands:"
    echo "  aws s3 cp s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/$CLIENT_NAME.conf ./"
    echo "  aws s3 cp s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/README.txt ./"
    echo ""
    echo "Or download all client files:"
    echo "  aws s3 sync s3://$SCRIPTS_BUCKET/wireguard/$CLIENT_NAME/ ./$CLIENT_NAME/"
else
    echo "S3 upload failed due to permissions. Client files are available locally:"
    echo "  Configuration: $LOCAL_BACKUP_DIR/$CLIENT_NAME.conf"
    echo "  Instructions:  $LOCAL_BACKUP_DIR/README.txt"
    echo ""
    echo "To distribute manually, copy files from: $LOCAL_BACKUP_DIR"
fi

# Clean up temporary files
rm -f /tmp/wg0.conf.current
rm -rf /tmp/client-$CLIENT_NAME

echo ""
echo "Client setup completed!"
if [ "$S3_UPLOAD_SUCCESS" = false ]; then
    echo "Note: Files are stored locally due to S3 permission issues."
    echo "Consider updating IAM permissions to enable S3 storage."
fi
