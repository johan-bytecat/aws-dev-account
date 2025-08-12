#!/bin/bash

# DNS Management Script for DevCloud Infrastructure
# This script can be used to manually update DNS records or check their status

DOMAIN_NAME="devcloud.bytecat.co.za"
LOG_FILE="/var/log/dns-maintenance.log"

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a "$LOG_FILE"
}

# Function to show usage
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  status     - Show current DNS records and IP addresses"
    echo "  update     - Force update DNS record for this instance"
    echo "  check      - Check if DNS record matches current IP"
    echo "  logs       - Show recent DNS update logs"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 update"
}

# Function to get hosted zone ID
get_hosted_zone_id() {
    aws route53 list-hosted-zones --query "HostedZones[?Name=='$DOMAIN_NAME.'].Id" --output text 2>/dev/null | cut -d'/' -f3
}

# Function to determine instance type and record name
get_instance_info() {
    # Get IMDSv2 token
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s --max-time 5 2>/dev/null)
    if [ -z "$TOKEN" ]; then
        log "Failed to retrieve IMDSv2 token"
        return 1
    fi
    
    # Check if this is a VPN/NAT instance (has public IP) or private instance
    PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
    PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s --max-time 5 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
    
    if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "404" ]; then
        # This is a VPN/NAT instance
        INSTANCE_TYPE="vpn-nat"
        RECORD_NAME="access.$DOMAIN_NAME"
        CURRENT_IP="$PUBLIC_IP"
        IP_TYPE="public"
    else
        # This is a private instance
        INSTANCE_TYPE="private"
        RECORD_NAME="kite.$DOMAIN_NAME"
        CURRENT_IP="$PRIVATE_IP"
        IP_TYPE="private"
    fi
}

# Function to get current DNS record
get_dns_record() {
    local hosted_zone_id="$1"
    local record_name="$2"
    
    aws route53 list-resource-record-sets \
        --hosted-zone-id "$hosted_zone_id" \
        --query "ResourceRecordSets[?Name=='$record_name.' && Type=='A'].ResourceRecords[0].Value" \
        --output text 2>/dev/null
}

# Function to update DNS record
update_dns_record() {
    local hosted_zone_id="$1"
    local record_name="$2"
    local ip_address="$3"
    
    local change_batch="{
        \"Changes\": [{
            \"Action\": \"UPSERT\",
            \"ResourceRecordSet\": {
                \"Name\": \"$record_name.\",
                \"Type\": \"A\",
                \"TTL\": 60,
                \"ResourceRecords\": [{ \"Value\": \"$ip_address\" }]
            }
        }]
    }"
    
    aws route53 change-resource-record-sets \
        --hosted-zone-id "$hosted_zone_id" \
        --change-batch "$change_batch"
}

# Main script logic
case "${1:-status}" in
    "status")
        log "=== DNS Status Report ==="
        
        get_instance_info
        log "Instance Type: $INSTANCE_TYPE"
        log "Record Name: $RECORD_NAME"
        log "Current $IP_TYPE IP: $CURRENT_IP"
        
        HOSTED_ZONE_ID=$(get_hosted_zone_id)
        if [ -n "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "None" ]; then
            log "Hosted Zone ID: $HOSTED_ZONE_ID"
            
            DNS_IP=$(get_dns_record "$HOSTED_ZONE_ID" "$RECORD_NAME")
            if [ -n "$DNS_IP" ] && [ "$DNS_IP" != "None" ]; then
                log "DNS Record IP: $DNS_IP"
                
                if [ "$CURRENT_IP" = "$DNS_IP" ]; then
                    log "✓ DNS record is current"
                else
                    log "✗ DNS record is outdated"
                fi
            else
                log "✗ DNS record not found"
            fi
        else
            log "✗ Hosted zone not found"
        fi
        ;;
        
    "update")
        log "=== Forcing DNS Record Update ==="
        
        get_instance_info
        log "Updating $RECORD_NAME to $CURRENT_IP"
        
        HOSTED_ZONE_ID=$(get_hosted_zone_id)
        if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" = "None" ]; then
            log "ERROR: Could not find hosted zone for $DOMAIN_NAME"
            exit 1
        fi
        
        if update_dns_record "$HOSTED_ZONE_ID" "$RECORD_NAME" "$CURRENT_IP" >/dev/null 2>&1; then
            log "✓ DNS record updated successfully"
        else
            log "✗ Failed to update DNS record"
            exit 1
        fi
        ;;
        
    "check")
        get_instance_info
        HOSTED_ZONE_ID=$(get_hosted_zone_id)
        
        if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" = "None" ]; then
            echo "ERROR: Hosted zone not found"
            exit 1
        fi
        
        DNS_IP=$(get_dns_record "$HOSTED_ZONE_ID" "$RECORD_NAME")
        
        if [ "$CURRENT_IP" = "$DNS_IP" ]; then
            echo "OK: DNS record matches current IP ($CURRENT_IP)"
            exit 0
        else
            echo "MISMATCH: Current IP ($CURRENT_IP) != DNS IP ($DNS_IP)"
            exit 1
        fi
        ;;
        
    "logs")
        if [ -f "$LOG_FILE" ]; then
            echo "=== Recent DNS Update Logs ==="
            tail -20 "$LOG_FILE"
        else
            echo "No DNS update logs found"
        fi
        
        if [ -f "/var/log/dns-update.log" ]; then
            echo ""
            echo "=== Recent Boot DNS Update Logs ==="
            tail -20 "/var/log/dns-update.log"
        fi
        ;;
        
    *)
        usage
        exit 1
        ;;
esac
