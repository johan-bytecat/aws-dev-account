#!/bin/bash

# VPN/NAT DNS Update Service
# This script runs on every boot to ensure the access.devcloud.bytecat.co.za DNS record
# is updated with the current public IP address in both public and private hosted zones

# Configuration
DOMAIN_NAME="devcloud.bytecat.co.za"
RECORD_NAME="access.$DOMAIN_NAME"
LOG_FILE="/var/log/dns-update.log"

# Load parameters from saved config if available
if [ -f "/opt/devcloud/config/init-parameters.env" ]; then
    source /opt/devcloud/config/init-parameters.env
    log "Loaded parameters from saved config"
fi

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

log "Starting DNS update service for $RECORD_NAME"

# Get hosted zone IDs from saved parameters or discover them
PRIVATE_HOSTED_ZONE_ID="${PRIVATE_HOSTED_ZONE_ID:-}"
PUBLIC_HOSTED_ZONE_ID="${PUBLIC_HOSTED_ZONE_ID:-}"
MAX_RETRIES=10
RETRY_COUNT=0

# If we don't have saved zone IDs, discover them
if [ -z "$PRIVATE_HOSTED_ZONE_ID" ] || [ -z "$PUBLIC_HOSTED_ZONE_ID" ]; then
    # Wait for AWS CLI and network to be ready
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if command -v aws >/dev/null 2>&1; then
            # Try to get hosted zone IDs
            if [ -z "$PRIVATE_HOSTED_ZONE_ID" ]; then
                PRIVATE_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='$DOMAIN_NAME.' && Config.PrivateZone==\`true\`].Id" --output text 2>/dev/null | cut -d'/' -f3)
            fi
            if [ -z "$PUBLIC_HOSTED_ZONE_ID" ]; then
                PUBLIC_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='$DOMAIN_NAME.' && Config.PrivateZone==\`false\`].Id" --output text 2>/dev/null | cut -d'/' -f3)
            fi
            
            if [ -n "$PRIVATE_HOSTED_ZONE_ID" ] && [ "$PRIVATE_HOSTED_ZONE_ID" != "None" ] && 
               [ -n "$PUBLIC_HOSTED_ZONE_ID" ] && [ "$PUBLIC_HOSTED_ZONE_ID" != "None" ]; then
                log "Found private hosted zone ID: $PRIVATE_HOSTED_ZONE_ID"
                log "Found public hosted zone ID: $PUBLIC_HOSTED_ZONE_ID"
                break
            fi
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        log "Attempt $RETRY_COUNT: AWS CLI not ready or hosted zones not found, retrying in 10 seconds..."
        sleep 10
    done
fi

if [ -z "$PRIVATE_HOSTED_ZONE_ID" ] || [ "$PRIVATE_HOSTED_ZONE_ID" = "None" ] ||
   [ -z "$PUBLIC_HOSTED_ZONE_ID" ] || [ "$PUBLIC_HOSTED_ZONE_ID" = "None" ]; then
    log "ERROR: Could not find both hosted zones for $DOMAIN_NAME after $MAX_RETRIES attempts"
    exit 1
fi

# Get current public IP
RETRY_COUNT=0
PUBLIC_IP=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Get IMDSv2 token
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s --max-time 10 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        # Get public IP using the token
        PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s --max-time 10 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
        if [ -n "$PUBLIC_IP" ] && [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log "Current public IP: $PUBLIC_IP"
            break
        fi
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    log "Attempt $RETRY_COUNT: Could not get public IP, retrying in 5 seconds..."
    sleep 5
done

if [ -z "$PUBLIC_IP" ]; then
    log "ERROR: Could not retrieve public IP address after $MAX_RETRIES attempts"
    exit 1
fi

# Get current DNS record IP from private zone (if exists)
CURRENT_PRIVATE_DNS_IP=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$PRIVATE_HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='$RECORD_NAME.' && Type=='A'].ResourceRecords[0].Value" \
    --output text 2>/dev/null)

# Get current DNS record IP from public zone (if exists)
CURRENT_PUBLIC_DNS_IP=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$PUBLIC_HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='$RECORD_NAME.' && Type=='A'].ResourceRecords[0].Value" \
    --output text 2>/dev/null)

if [ "$CURRENT_PRIVATE_DNS_IP" = "None" ] || [ -z "$CURRENT_PRIVATE_DNS_IP" ]; then
    log "No existing DNS record found for $RECORD_NAME in private zone"
    CURRENT_PRIVATE_DNS_IP="none"
fi

if [ "$CURRENT_PUBLIC_DNS_IP" = "None" ] || [ -z "$CURRENT_PUBLIC_DNS_IP" ]; then
    log "No existing DNS record found for $RECORD_NAME in public zone"
    CURRENT_PUBLIC_DNS_IP="none"
fi

# Function to update DNS record in a specific zone
update_dns_record() {
    local zone_id="$1"
    local zone_name="$2"
    local current_ip="$3"
    
    if [ "$PUBLIC_IP" != "$current_ip" ]; then
        log "IP changed in $zone_name zone from $current_ip to $PUBLIC_IP, updating DNS record..."
        
        CHANGE_BATCH="{
            \"Changes\": [{
                \"Action\": \"UPSERT\",
                \"ResourceRecordSet\": {
                    \"Name\": \"$RECORD_NAME.\",
                    \"Type\": \"A\",
                    \"TTL\": 60,
                    \"ResourceRecords\": [{ \"Value\": \"$PUBLIC_IP\" }]
                }
            }]
        }"
        
        if aws route53 change-resource-record-sets \
            --hosted-zone-id "$zone_id" \
            --change-batch "$CHANGE_BATCH" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS: DNS record updated successfully in $zone_name zone for $RECORD_NAME -> $PUBLIC_IP"
            return 0
        else
            log "ERROR: Failed to update DNS record in $zone_name zone for $RECORD_NAME"
            return 1
        fi
    else
        log "DNS record already current in $zone_name zone: $RECORD_NAME -> $PUBLIC_IP (no update needed)"
        return 0
    fi
}

# Update DNS record in both zones
PRIVATE_UPDATE_SUCCESS=0
PUBLIC_UPDATE_SUCCESS=0

update_dns_record "$PRIVATE_HOSTED_ZONE_ID" "private" "$CURRENT_PRIVATE_DNS_IP"
PRIVATE_UPDATE_SUCCESS=$?

update_dns_record "$PUBLIC_HOSTED_ZONE_ID" "public" "$CURRENT_PUBLIC_DNS_IP"
PUBLIC_UPDATE_SUCCESS=$?

if [ $PRIVATE_UPDATE_SUCCESS -eq 0 ] && [ $PUBLIC_UPDATE_SUCCESS -eq 0 ]; then
    log "DNS update service completed successfully for both zones"
    exit 0
else
    log "DNS update service completed with errors"
    exit 1
fi
