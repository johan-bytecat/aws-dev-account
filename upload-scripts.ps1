#!/usr/bin/env pwsh

# Script to upload initialization and configuration scripts to S3
# Run this after deploying the network infrastructure but before starting instances

param(
    [Parameter(Mandatory=$false)]
    [string]$NetworkStackName = "devcloud-network",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "Uploading scripts to S3..." -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Network Stack: $NetworkStackName" -ForegroundColor Yellow

# Get the scripts bucket name from CloudFormation stack
try {
    $outputs = aws cloudformation describe-stacks --stack-name $NetworkStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output json | ConvertFrom-Json
    $scriptsBucket = ($outputs | Where-Object { $_.OutputKey -eq "ScriptsBucketName" }).OutputValue
    
    if (!$scriptsBucket) {
        throw "Could not retrieve ScriptsBucketName from stack outputs"
    }
    
    Write-Host "Scripts bucket: $scriptsBucket" -ForegroundColor Yellow
    
} catch {
    Write-Error "Error retrieving bucket name: $_"
    Write-Host "Make sure the network stack '$NetworkStackName' is deployed first." -ForegroundColor Yellow
    exit 1
}

# Create the scripts directory structure if it doesn't exist
if (!(Test-Path "scripts")) {
    Write-Host "Creating scripts directory structure..." -ForegroundColor Blue
    New-Item -ItemType Directory -Path "scripts\init" -Force | Out-Null
    New-Item -ItemType Directory -Path "scripts\vpn-nat" -Force | Out-Null
    New-Item -ItemType Directory -Path "scripts\private-instance" -Force | Out-Null
    New-Item -ItemType Directory -Path "scripts\wireguard" -Force | Out-Null
    New-Item -ItemType Directory -Path "scripts\wireguard\clients" -Force | Out-Null
}

# Check if initialization scripts exist
$requiredScripts = @(
    "scripts\init\vpn-nat-init.sh",
    "scripts\init\private-instance-init.sh"
)

$missingScripts = @()
foreach ($script in $requiredScripts) {
    if (!(Test-Path $script)) {
        $missingScripts += $script
    }
}

if ($missingScripts.Count -gt 0) {
    Write-Host "Missing required scripts:" -ForegroundColor Red
    foreach ($script in $missingScripts) {
        Write-Host "  - $script" -ForegroundColor Red
    }
    Write-Host "Please ensure all initialization scripts are created first." -ForegroundColor Red
    exit 1
}

# Upload initialization scripts
Write-Host "`nUploading initialization scripts..." -ForegroundColor Blue
try {
    aws s3 cp scripts\init\vpn-nat-init.sh s3://$scriptsBucket/init/vpn-nat-init.sh
    aws s3 cp scripts\init\private-instance-init.sh s3://$scriptsBucket/init/private-instance-init.sh
    Write-Host "✓ Initialization scripts uploaded" -ForegroundColor Green
} catch {
    Write-Error "Failed to upload initialization scripts: $_"
    exit 1
}

# Upload additional scripts if they exist
if (Test-Path "scripts\vpn-nat") {
    Write-Host "`nUploading VPN/NAT scripts..." -ForegroundColor Blue
    aws s3 sync scripts\vpn-nat\ s3://$scriptsBucket/vpn-nat/
    Write-Host "✓ VPN/NAT scripts uploaded" -ForegroundColor Green
}

if (Test-Path "scripts\private-instance") {
    Write-Host "`nUploading private instance scripts..." -ForegroundColor Blue
    aws s3 sync scripts\private-instance\ s3://$scriptsBucket/private-instance/
    Write-Host "✓ Private instance scripts uploaded" -ForegroundColor Green
}

# Create placeholder files for WireGuard directory
Write-Host "`nCreating WireGuard directory structure..." -ForegroundColor Blue
try {
    # Create the wireguard directory if it doesn't exist
    if (!(Test-Path "scripts\wireguard")) {
        New-Item -ItemType Directory -Path "scripts\wireguard" -Force | Out-Null
    }
    
    # Create a README file for the wireguard directory
    $wgReadme = @"
# WireGuard Configuration Directory

This directory will contain:
- server-private.key: Server private key (generated on first boot)
- server-public.key: Server public key (generated on first boot)
- wg0.conf: Server configuration file
- clients/: Directory containing client configurations

Files will be automatically created when the VPN instance first starts.
"@
    
    $wgReadme | Out-File -FilePath "scripts\wireguard\README.md" -Encoding UTF8
    aws s3 cp scripts\wireguard\README.md s3://$scriptsBucket/wireguard/README.md
    
    # Ensure the clients directory exists
    aws s3api put-object --bucket $scriptsBucket --key wireguard/clients/ --body /dev/null
    
    Write-Host "✓ WireGuard directory structure created" -ForegroundColor Green
} catch {
    Write-Error "Failed to create WireGuard directory: $_"
    exit 1
}

# Note: add-wireguard-client.sh is now included in vpn-nat directory sync above

Write-Host "`n" + "="*50 -ForegroundColor Blue
Write-Host "UPLOAD COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "="*50 -ForegroundColor Blue

Write-Host "`nScripts uploaded to: s3://$scriptsBucket" -ForegroundColor Yellow
Write-Host "`nDirectory structure:" -ForegroundColor Yellow
Write-Host "  init/                    - Instance initialization scripts" -ForegroundColor White
Write-Host "  vpn-nat/                 - VPN/NAT specific scripts" -ForegroundColor White
Write-Host "  private-instance/        - Private instance specific scripts" -ForegroundColor White
Write-Host "  wireguard/               - WireGuard configuration and keys" -ForegroundColor White
Write-Host "  wireguard/clients/       - Client configurations" -ForegroundColor White

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "1. Start your instances (they will automatically download and run init scripts)" -ForegroundColor White
Write-Host "2. Add WireGuard clients using the updated add-wireguard-client.sh script" -ForegroundColor White
Write-Host "3. Client configurations will be saved to S3 for easy access" -ForegroundColor White

# Clean up local README file
Remove-Item "scripts\wireguard\README.md" -ErrorAction SilentlyContinue
