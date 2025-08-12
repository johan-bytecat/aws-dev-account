#!/bin/bash

# VPN/NAT Gateway monitoring and maintenance script
# This script can be run periodically to maintain the VPN/NAT gateway

SCRIPTS_BUCKET="$1"
LOG_FILE="/var/log/vpn-maintenance.log"

echo "$(date): Starting VPN/NAT maintenance" >> $LOG_FILE

# Function to log messages
log_message() {
    echo "$(date): $1" >> $LOG_FILE
    echo "$1"
}

# Check WireGuard status
check_wireguard() {
    log_message "Checking WireGuard status..."
    if systemctl is-active --quiet wg-quick@wg0; then
        log_message "WireGuard is running"
        wg show >> $LOG_FILE
    else
        log_message "WARNING: WireGuard is not running, attempting restart"
        systemctl restart wg-quick@wg0
        sleep 5
        if systemctl is-active --quiet wg-quick@wg0; then
            log_message "WireGuard restarted successfully"
        else
            log_message "ERROR: Failed to restart WireGuard"
        fi
    fi
}

# Check NAT functionality
check_nat() {
    log_message "Checking NAT rules..."
    iptables -t nat -L POSTROUTING | grep MASQUERADE >/dev/null
    if [ $? -eq 0 ]; then
        log_message "NAT rules are present"
    else
        log_message "WARNING: NAT rules missing, restoring..."
        iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
        service iptables save
    fi
}

# Backup configuration to S3
backup_config() {
    log_message "Backing up configuration to S3..."
    
    # Backup WireGuard configuration
    if [ -f /etc/wireguard/wg0.conf ]; then
        aws s3 cp /etc/wireguard/wg0.conf s3://$SCRIPTS_BUCKET/wireguard/wg0.conf
    fi
    
    # Backup iptables rules
    iptables-save > /tmp/iptables-backup.rules
    aws s3 cp /tmp/iptables-backup.rules s3://$SCRIPTS_BUCKET/backups/iptables-$(date +%Y%m%d).rules
    rm /tmp/iptables-backup.rules
    
    log_message "Configuration backup completed"
}

# Update DNS if public IP changed
update_dns_if_needed() {
    log_message "Checking if DNS update is needed..."
    
    # Get IMDSv2 token
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
    if [ -z "$TOKEN" ]; then
        log_message "Failed to retrieve IMDSv2 token"
        return 1
    fi
    
    # Get current IP using the token
    CURRENT_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/public-ipv4)
    DOMAIN_NAME=$(aws cloudformation describe-stacks --stack-name devcloud-infrastructure --region af-south-1 --query 'Stacks[0].Parameters[?ParameterKey==`DomainName`].ParameterValue' --output text)
    
    # Get current DNS record
    HOSTED_ZONE_ID=$(aws cloudformation describe-stacks --stack-name devcloud-infrastructure --region af-south-1 --query 'Stacks[0].Outputs[?OutputKey==`HostedZoneId`].OutputValue' --output text)
    DNS_IP=$(aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --query "ResourceRecordSets[?Name=='access.$DOMAIN_NAME.'].ResourceRecords[0].Value" --output text)
    
    if [ "$CURRENT_IP" != "$DNS_IP" ]; then
        log_message "IP changed from $DNS_IP to $CURRENT_IP, updating DNS..."
        aws route53 change-resource-record-sets \
          --hosted-zone-id $HOSTED_ZONE_ID \
          --change-batch "{
            \"Changes\": [{
              \"Action\": \"UPSERT\",
              \"ResourceRecordSet\": {
                \"Name\": \"access.$DOMAIN_NAME.\",
                \"Type\": \"A\",
                \"TTL\": 60,
                \"ResourceRecords\": [{ \"Value\": \"$CURRENT_IP\" }]
              }
            }]
          }"
        log_message "DNS updated successfully"
    else
        log_message "DNS record is current"
    fi
}

# Run maintenance tasks
check_wireguard
check_nat
backup_config
update_dns_if_needed

# Upload log file to S3
aws s3 cp $LOG_FILE s3://$SCRIPTS_BUCKET/logs/vpn-maintenance-$(date +%Y%m%d).log

log_message "VPN/NAT maintenance completed"
