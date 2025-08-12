#!/bin/bash

# Private Instance DNS Update Service
# This script runs on every boot to ensure the kite.devcloud.bytecat.co.za DNS record
# is updated with the current private IP address in the private hosted zone only

# Configuration
DOMAIN_NAME="devcloud.bytecat.co.za"
RECORD_NAME="kite.$DOMAIN_NAME"
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

# Get private hosted zone ID from saved parameters or discover it
PRIVATE_HOSTED_ZONE_ID="${PRIVATE_HOSTED_ZONE_ID:-}"
MAX_RETRIES=10
RETRY_COUNT=0

# If we don't have saved zone ID, discover it
if [ -z "$PRIVATE_HOSTED_ZONE_ID" ]; then
    # Wait for AWS CLI and network to be ready
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if command -v aws >/dev/null 2>&1; then
            # Try to get private hosted zone ID
            PRIVATE_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='$DOMAIN_NAME.' && Config.PrivateZone==\`true\`].Id" --output text 2>/dev/null | cut -d'/' -f3)
            if [ -n "$PRIVATE_HOSTED_ZONE_ID" ] && [ "$PRIVATE_HOSTED_ZONE_ID" != "None" ]; then
                log "Found private hosted zone ID: $PRIVATE_HOSTED_ZONE_ID"
                break
            fi
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        log "Attempt $RETRY_COUNT: AWS CLI not ready or private hosted zone not found, retrying in 10 seconds..."
        sleep 10
    done
fi

if [ -z "$PRIVATE_HOSTED_ZONE_ID" ] || [ "$PRIVATE_HOSTED_ZONE_ID" = "None" ]; then
    log "ERROR: Could not find private hosted zone for $DOMAIN_NAME after $MAX_RETRIES attempts"
    exit 1
fi

# Get current private IP
RETRY_COUNT=0
PRIVATE_IP=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Get IMDSv2 token
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s --max-time 10 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        # Get private IP using the token
        PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s --max-time 10 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
        if [ -n "$PRIVATE_IP" ] && [[ $PRIVATE_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log "Current private IP: $PRIVATE_IP"
            break
        fi
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    log "Attempt $RETRY_COUNT: Could not get private IP, retrying in 5 seconds..."
    sleep 5
done

if [ -z "$PRIVATE_IP" ]; then
    log "ERROR: Could not retrieve private IP address after $MAX_RETRIES attempts"
    exit 1
fi

# Get current DNS record IP from private zone (if exists)
CURRENT_DNS_IP=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$PRIVATE_HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='$RECORD_NAME.' && Type=='A'].ResourceRecords[0].Value" \
    --output text 2>/dev/null)

if [ "$CURRENT_DNS_IP" = "None" ] || [ -z "$CURRENT_DNS_IP" ]; then
    log "No existing DNS record found for $RECORD_NAME in private zone"
    CURRENT_DNS_IP="none"
fi

# Update DNS record if IP has changed
if [ "$PRIVATE_IP" != "$CURRENT_DNS_IP" ]; then
    log "IP changed from $CURRENT_DNS_IP to $PRIVATE_IP, updating DNS record in private zone..."
    
    CHANGE_BATCH="{
        \"Changes\": [{
            \"Action\": \"UPSERT\",
            \"ResourceRecordSet\": {
                \"Name\": \"$RECORD_NAME.\",
                \"Type\": \"A\",
                \"TTL\": 60,
                \"ResourceRecords\": [{ \"Value\": \"$PRIVATE_IP\" }]
            }
        }]
    }"
    
    if aws route53 change-resource-record-sets \
        --hosted-zone-id "$PRIVATE_HOSTED_ZONE_ID" \
        --change-batch "$CHANGE_BATCH" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS: DNS record updated successfully in private zone for $RECORD_NAME -> $PRIVATE_IP"
    else
        log "ERROR: Failed to update DNS record in private zone for $RECORD_NAME"
        exit 1
    fi
else
    log "DNS record already current in private zone: $RECORD_NAME -> $PRIVATE_IP (no update needed)"
fi

log "DNS update service completed successfully"
