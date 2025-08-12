#!/usr/bin/env pwsh

# AWS DevCloud Phase 3: Private Instance Deployment Script
# Deploys: Private instance that depends on VPN/NAT Gateway

param(
    [Parameter(Mandatory=$true)]
    [string]$KeyPairName,
    
    [Parameter(Mandatory=$false)]
    [string]$FoundationStackName = "devcloud-foundation",
    
    [Parameter(Mandatory=$false)]
    [string]$VPNNATStackName = "devcloud-vpn-nat",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateStackName = "devcloud-private",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$DomainName = "devcloud.bytecat.co.za",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateInstanceIP = "172.16.2.100",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud Phase 3: Private Instance Deployment" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "VPN/NAT Stack: $VPNNATStackName" -ForegroundColor Yellow
Write-Host "Private Stack: $PrivateStackName" -ForegroundColor Yellow
Write-Host "Key Pair: $KeyPairName" -ForegroundColor Yellow
Write-Host "Domain: $DomainName" -ForegroundColor Yellow
Write-Host "Private Instance IP: $PrivateInstanceIP" -ForegroundColor Yellow

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "Deploying to AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

# Check if key pair exists
try {
    aws ec2 describe-key-pairs --key-names $KeyPairName --region $Region --profile $Profile --output table | Out-Null
    Write-Host "Key pair '$KeyPairName' found" -ForegroundColor Green
} catch {
    Write-Error "Key pair '$KeyPairName' not found in region $Region"
    Write-Host "Create a key pair first with: aws ec2 create-key-pair --key-name $KeyPairName --region $Region --profile $Profile" -ForegroundColor Yellow
    exit 1
}

# Check if foundation stack exists
try {
    aws cloudformation describe-stacks --stack-name $FoundationStackName --region $Region --profile $Profile --output table | Out-Null
    Write-Host "Foundation stack '$FoundationStackName' found" -ForegroundColor Green
} catch {
    Write-Error "Foundation stack '$FoundationStackName' not found in region $Region"
    Write-Host "Deploy Phase 1 first with: .\deploy-phase1.ps1" -ForegroundColor Yellow
    exit 1
}

# Check if VPN/NAT stack exists
try {
    $vpnNatStack = aws cloudformation describe-stacks --stack-name $VPNNATStackName --region $Region --profile $Profile --output json | ConvertFrom-Json
    Write-Host "VPN/NAT stack '$VPNNATStackName' found" -ForegroundColor Green
    
    # Check if VPN/NAT stack is in a good state
    $stackStatus = $vpnNatStack.Stacks[0].StackStatus
    if ($stackStatus -eq "CREATE_COMPLETE" -or $stackStatus -eq "UPDATE_COMPLETE") {
        Write-Host "VPN/NAT stack status: $stackStatus ✓" -ForegroundColor Green
    } else {
        Write-Error "VPN/NAT stack is in state: $stackStatus. Deploy Phase 2 successfully first."
        exit 1
    }
} catch {
    Write-Error "VPN/NAT stack '$VPNNATStackName' not found in region $Region"
    Write-Host "Deploy Phase 2 first with: .\deploy-phase2.ps1" -ForegroundColor Yellow
    exit 1
}

# Get VPN/NAT instance information for verification
try {
    Write-Host "`nVerifying VPN/NAT Gateway status..." -ForegroundColor Yellow
    $vpnNatOutputs = $vpnNatStack.Stacks[0].Outputs
    $vpnNatInstanceId = ($vpnNatOutputs | Where-Object { $_.OutputKey -eq "VPNNATInstanceId" }).OutputValue
    $vpnNatPublicIP = ($vpnNatOutputs | Where-Object { $_.OutputKey -eq "VPNNATPublicIP" }).OutputValue
    $vpnNatPrivateIP = ($vpnNatOutputs | Where-Object { $_.OutputKey -eq "VPNNATPrivateIP" }).OutputValue
    
    Write-Host "VPN/NAT Instance ID: $vpnNatInstanceId" -ForegroundColor Cyan
    Write-Host "VPN/NAT Public IP: $vpnNatPublicIP" -ForegroundColor Cyan
    Write-Host "VPN/NAT Private IP: $vpnNatPrivateIP" -ForegroundColor Cyan
    
    # Check instance state
    $instanceState = aws ec2 describe-instances --instance-ids $vpnNatInstanceId --region $Region --profile $Profile --query 'Reservations[0].Instances[0].State.Name' --output text
    Write-Host "VPN/NAT Instance State: $instanceState" -ForegroundColor Cyan
    
    if ($instanceState -ne "running") {
        Write-Warning "VPN/NAT instance is not running. The private instance may not have internet connectivity."
        Write-Host "Consider starting the VPN/NAT instance first: .\manage-instances.ps1 -Action start -Instance vpn-nat -StackName $VPNNATStackName" -ForegroundColor Yellow
        Write-Host "Press Enter to continue anyway or Ctrl+C to cancel..." -ForegroundColor Yellow
        Read-Host
    } else {
        Write-Host "✓ VPN/NAT Gateway is running and ready" -ForegroundColor Green
    }
} catch {
    Write-Warning "Could not verify VPN/NAT Gateway status: $_"
    Write-Host "Proceeding with deployment..." -ForegroundColor Yellow
}

# Verify scripts are uploaded
Write-Host "`nVerifying scripts are uploaded to S3..." -ForegroundColor Yellow
Write-Host "Make sure you have run: .\upload-scripts.ps1 -StackName $FoundationStackName" -ForegroundColor Cyan
Write-Host "Press Enter to continue or Ctrl+C to cancel..." -ForegroundColor Yellow
Read-Host

# Phase 3: Deploy Private Instance
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "PHASE 3: DEPLOYING PRIVATE INSTANCE" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Deploying Private Instance stack..." -ForegroundColor Blue
    
    $privateArgs = @(
        "cloudformation", "deploy",
        "--template-file", "phase3-private-instance.yaml",
        "--stack-name", $PrivateStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_IAM",
        "--parameter-overrides", "KeyPairName=$KeyPairName", "FoundationStackName=$FoundationStackName", "VPNNATStackName=$VPNNATStackName", "DomainName=$DomainName", "PrivateInstanceIP=$PrivateInstanceIP",
        "--output", "table"
    )
    
    & aws @privateArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Private Instance stack deployed successfully!" -ForegroundColor Green
        
        # Get Private Instance stack outputs
        Write-Host "`nPrivate Instance Stack Outputs:" -ForegroundColor Blue
        aws cloudformation describe-stacks --stack-name $PrivateStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output table
        
    } else {
        Write-Error "Private Instance stack deployment failed"
        exit 1
    }
} catch {
    Write-Error "Error deploying Private Instance stack: $_"
    exit 1
}

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "PHASE 3 PRIVATE INSTANCE DEPLOYMENT COMPLETED!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Configure WireGuard clients" -ForegroundColor White
Write-Host "2. Add client public keys to the VPN server" -ForegroundColor White
Write-Host "3. Test connectivity through the VPN" -ForegroundColor White
Write-Host "4. Access private instance through VPN" -ForegroundColor White
Write-Host "5. Deploy user management group (optional): .\deploy-user-group.ps1" -ForegroundColor White

Write-Host "`nInstance Management:" -ForegroundColor Yellow
Write-Host "  VPN/NAT: .\manage-instances.ps1 -Action status -Instance vpn-nat -StackName $VPNNATStackName" -ForegroundColor White
Write-Host "  Private: .\manage-instances.ps1 -Action status -Instance private -StackName $PrivateStackName" -ForegroundColor White
Write-Host "  Both:    .\manage-instances.ps1 -Action status -Instance both" -ForegroundColor White

Write-Host "`nConnectivity Testing:" -ForegroundColor Yellow
Write-Host "  Test VPN connection to private instance:" -ForegroundColor White
Write-Host "  ssh -i bytecatdev1.pem ec2-user@$PrivateInstanceIP" -ForegroundColor Cyan

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "COMPLETE DEPLOYMENT FINISHED!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green
