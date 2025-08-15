#!/usr/bin/env pwsh

# AWS DevCloud Phase 2: VPN/NAT Gateway Deployment Script
# Deploys: VPN/NAT Gateway Instance only

param(
    [Parameter(Mandatory=$true)]
    [string]$KeyPairName,
    
    [Parameter(Mandatory=$false)]
    [string]$PublicHostedZoneId = "Z01350882HWVKQIM61CH3",
    
    [Parameter(Mandatory=$false)]
    [string]$FoundationStackName = "devcloud-foundation",
    
    [Parameter(Mandatory=$false)]
    [string]$IAMStackName = "devcloud-iam-roles",
    
    [Parameter(Mandatory=$false)]
    [string]$ComputeStackName = "devcloud-vpn-nat",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$DomainName = "devcloud.bytecat.co.za",
    
    [Parameter(Mandatory=$false)]
    [string]$VPNNATPrivateIP = "172.16.1.100",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud Phase 2: VPN/NAT Gateway Deployment" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "IAM Stack: $IAMStackName" -ForegroundColor Yellow
Write-Host "Compute Stack: $ComputeStackName" -ForegroundColor Yellow
Write-Host "Key Pair: $KeyPairName" -ForegroundColor Yellow
Write-Host "Domain: $DomainName" -ForegroundColor Yellow
Write-Host "Public Hosted Zone ID: $PublicHostedZoneId" -ForegroundColor Yellow
Write-Host "VPN/NAT Private IP: $VPNNATPrivateIP" -ForegroundColor Yellow

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
    Write-Host "✓ Foundation stack '$FoundationStackName' found" -ForegroundColor Green
} catch {
    Write-Error "Foundation stack '$FoundationStackName' not found in region $Region"
    Write-Host "Deploy Phase 1 first with: .\deploy-phase1.ps1" -ForegroundColor Yellow
    exit 1
}

# Check if IAM stack exists
try {
    aws cloudformation describe-stacks --stack-name $IAMStackName --region $Region --profile $Profile --output table | Out-Null
    Write-Host "✓ IAM stack '$IAMStackName' found" -ForegroundColor Green
} catch {
    Write-Error "IAM stack '$IAMStackName' not found in region $Region"
    Write-Host "Deploy IAM roles first with: .\deploy-iam-roles.ps1 -FoundationStackName $FoundationStackName" -ForegroundColor Yellow
    exit 1
}

# Verify scripts are uploaded
Write-Host "`nVerifying scripts are uploaded to S3..." -ForegroundColor Yellow
Write-Host "Make sure you have run: .\upload-scripts.ps1 -StackName $FoundationStackName" -ForegroundColor Cyan
Write-Host "Press Enter to continue or Ctrl+C to cancel..." -ForegroundColor Yellow
Read-Host

# Phase 2: Deploy VPN/NAT Gateway
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "PHASE 2: DEPLOYING VPN/NAT GATEWAY" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Deploying VPN/NAT Gateway stack..." -ForegroundColor Blue
    
    $computeArgs = @(
        "cloudformation", "deploy",
        "--template-file", "phase2-vpn-nat.yaml",
        "--stack-name", $ComputeStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_IAM",
        "--parameter-overrides", "KeyPairName=$KeyPairName", "FoundationStackName=$FoundationStackName", "IAMStackName=$IAMStackName", "PublicHostedZoneId=$PublicHostedZoneId", "DomainName=$DomainName", "VPNNATPrivateIP=$VPNNATPrivateIP",
        "--output", "table"
    )
    
    & aws @computeArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ VPN/NAT Gateway stack deployed successfully!" -ForegroundColor Green
        
        # Get VPN/NAT stack outputs
        Write-Host "`nVPN/NAT Gateway Stack Outputs:" -ForegroundColor Blue
        aws cloudformation describe-stacks --stack-name $ComputeStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output table
        
    } else {
        Write-Error "VPN/NAT Gateway stack deployment failed"
        exit 1
    }
} catch {
    Write-Error "Error deploying VPN/NAT Gateway stack: $_"
    exit 1
}

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "PHASE 2 VPN/NAT GATEWAY DEPLOYMENT COMPLETED!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Wait for VPN/NAT Gateway to fully initialize (check CloudWatch logs)" -ForegroundColor White
Write-Host "2. Test VPN connectivity" -ForegroundColor White
Write-Host "3. Deploy Phase 3 (Private Instance): .\deploy-phase3.ps1" -ForegroundColor White
Write-Host "4. Deploy user management group (optional): .\deploy-user-group.ps1" -ForegroundColor White

Write-Host "`nVPN/NAT Instance Management:" -ForegroundColor Yellow
Write-Host "  .\manage-instances.ps1 -Action start -Instance vpn-nat -StackName $ComputeStackName" -ForegroundColor White
Write-Host "  .\manage-instances.ps1 -Action status -Instance vpn-nat -StackName $ComputeStackName" -ForegroundColor White
