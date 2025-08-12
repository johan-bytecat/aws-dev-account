#!/bin/bash

# Comprehensive iptables setup for VPN/NAT Gateway
# This script configures secure iptables rules for a WireGuard VPN server
# that also acts as a NAT gateway for a private VPC subnet

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "=== Starting Comprehensive iptables Configuration ==="

# Install iptables-services if not already installed
if ! command -v iptables-save >/dev/null 2>&1; then
    log "Installing iptables-services..."
    yum install -y iptables-services
fi

# Clear existing rules and chains
log "Clearing existing iptables rules..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Set default policies (DROP for security)
log "Setting default policies..."
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Enable loopback traffic (essential for system operation)
log "Enabling loopback traffic..."
iptables -A INPUT -i lo -j ACCEPT

# Accept established/related incoming connections (stateful firewall)
log "Enabling stateful connection tracking..."
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Configure security protections
log "Configuring security protections..."

# Drop invalid packets
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# Rate limit SSH to prevent brute force attacks (max 3 attempts per minute)
log "Configuring rate-limited SSH access..."
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set --name SSH
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 --name SSH -j LOG --log-prefix "SSH-BRUTE: "
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Allow WireGuard VPN traffic (port 51820)
log "Allowing WireGuard VPN traffic..."
iptables -A INPUT -p udp --dport 51820 -j ACCEPT

# Allow limited ICMP (ping and essential types only)
log "Allowing limited ICMP traffic..."
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/sec -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT
iptables -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
iptables -A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT

# Log and drop any remaining input attempts (security monitoring)
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "INPUT-DROP: "
iptables -A INPUT -j DROP

# Configure forwarding rules for VPN traffic
log "Configuring VPN forwarding rules..."

# Drop invalid packets in forwarding
iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP

# Allow forwarding for established/related connections
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Allow VPN clients (WireGuard subnet) to access VPC resources
iptables -A FORWARD -s 10.0.0.0/24 -d 172.16.0.0/16 -j ACCEPT

# Allow VPC resources to respond to VPN clients
iptables -A FORWARD -s 172.16.0.0/16 -d 10.0.0.0/24 -j ACCEPT

# Configure NAT functionality for VPC to Internet access
log "Configuring VPC to Internet forwarding rules..."

# Allow VPC subnet to access Internet via ens5 (outbound traffic)
iptables -A FORWARD -s 172.16.0.0/16 -o ens5 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT

# Allow return traffic from Internet to VPC via ens5 (inbound responses only)
iptables -A FORWARD -d 172.16.0.0/16 -i ens5 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Log and drop any remaining forward attempts (security monitoring)
iptables -A FORWARD -m limit --limit 5/min -j LOG --log-prefix "FORWARD-DROP: "
iptables -A FORWARD -j DROP

# Configure NAT for outbound internet access
log "Configuring NAT masquerading..."
# NAT masquerading for VPC subnet only (for outbound internet access)
iptables -t nat -A POSTROUTING -s 172.16.0.0/16 -o ens5 -j MASQUERADE

# Display configured rules for verification
log "Current iptables rules:"
iptables -L -v -n --line-numbers
echo ""
log "Current NAT rules:"
iptables -t nat -L -v -n --line-numbers

# Make rules persistent across reboots
log "Making iptables rules persistent..."

# Ensure directory exists
mkdir -p /etc/sysconfig

# Save current rules
iptables-save > /etc/sysconfig/iptables

# Create systemd service for automatic restore on boot
log "Creating iptables-restore systemd service..."
cat <<EOF > /etc/systemd/system/iptables-restore.service
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/sysconfig/iptables
ExecReload=/sbin/iptables-restore /etc/sysconfig/iptables
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
log "Enabling iptables-restore service..."
systemctl daemon-reload
systemctl enable iptables-restore.service
systemctl start iptables-restore.service

# Verify service status
if systemctl is-active --quiet iptables-restore.service; then
    log "✓ iptables-restore service is active"
else
    log "✗ iptables-restore service failed to start"
    systemctl status iptables-restore.service --no-pager
    exit 1
fi

log "=== iptables Configuration Completed Successfully ==="
log "Rules summary:"
log "  - SSH access: Rate-limited (max 3 attempts/min, port 22)"
log "  - WireGuard VPN: Allowed (port 51820 UDP)"
log "  - ICMP ping: Rate-limited (5/sec, essential types only)"
log "  - VPN to VPC: Allowed (10.0.0.0/24 → 172.16.0.0/16)"
log "  - VPC to VPN: Allowed (172.16.0.0/16 → 10.0.0.0/24)"
log "  - VPC to Internet: Allowed (172.16.0.0/16 → Internet via ens5)"
log "  - Internet to VPC: Allowed (established/related responses only)"
log "  - Internet NAT: Enabled for VPC subnet (172.16.0.0/16)"
log "  - VPN Internet access: BLOCKED (VPN clients cannot use NAT)"
log "  - Invalid packets: DROPPED and logged"
log "  - Brute force protection: SSH rate limiting enabled"
log "  - Security logging: Enabled for dropped packets"
log "  - Default policy: DROP (secure)"
log "  - Persistence: Configured via systemd service"
log "================================================================"
