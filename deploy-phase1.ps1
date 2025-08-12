#!/usr/bin/env pwsh

# AWS DevCloud Phase 1: Foundation Infrastructure Deployment Script
# Deploys: S3, VPC, IAM, EFS

param(
    [Parameter(Mandatory=$false)]
    [string]$PublicHostedZoneId = "Z01350882HWVKQIM61CH3",
    
    [Parameter(Mandatory=$false)]
    [string]$FoundationStackName = "devcloud-foundation",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$DomainName = "devcloud.bytecat.co.za",
    
    [Parameter(Mandatory=$false)]
    [string]$VpcCidr = "172.16.0.0/16",
    
    [Parameter(Mandatory=$false)]
    [string]$PublicSubnetCidr = "172.16.1.0/24",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateSubnetCidr = "172.16.2.0/24",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateHostedZoneId = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud Phase 1: Foundation Infrastructure Deployment" -ForegroundColor Green
Write-Host "=======================================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "Domain: $DomainName" -ForegroundColor Yellow
Write-Host "Public Hosted Zone ID: $PublicHostedZoneId" -ForegroundColor Yellow
if ($PrivateHostedZoneId) {
    Write-Host "Private Hosted Zone ID: $PrivateHostedZoneId" -ForegroundColor Yellow
} else {
    Write-Host "Private Hosted Zone: Will be created" -ForegroundColor Yellow
}

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "Deploying to AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

# Phase 1: Deploy Foundation Infrastructure
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "PHASE 1: DEPLOYING FOUNDATION INFRASTRUCTURE" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Deploying foundation stack (S3, VPC, IAM, EFS)..." -ForegroundColor Blue
    
    $foundationArgs = @(
        "cloudformation", "deploy",
        "--template-file", "foundation-infrastructure.yaml",
        "--stack-name", $FoundationStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_NAMED_IAM",
        "--parameter-overrides", "DomainName=$DomainName", "VpcCidr=$VpcCidr", "PublicSubnetCidr=$PublicSubnetCidr", "PrivateSubnetCidr=$PrivateSubnetCidr", "PublicHostedZoneId=$PublicHostedZoneId", "PrivateHostedZoneId=$PrivateHostedZoneId",
        "--output", "table"
    )
    
    & aws @foundationArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Foundation stack deployed successfully!" -ForegroundColor Green
        
        # Get foundation stack outputs
        Write-Host "`nFoundation Stack Outputs:" -ForegroundColor Blue
        aws cloudformation describe-stacks --stack-name $FoundationStackName --region $Region --query 'Stacks[0].Outputs' --output table
        
    } else {
        Write-Error "Foundation stack deployment failed"
        exit 1
    }
} catch {
    Write-Error "Error deploying foundation stack: $_"
    exit 1
}

# Upload Scripts Instructions
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "NEXT: UPLOAD SCRIPTS TO S3" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

Write-Host "`nPhase 1 completed successfully!" -ForegroundColor Green
Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Upload scripts to S3 bucket:" -ForegroundColor White
Write-Host "   .\upload-scripts.ps1 -StackName $FoundationStackName" -ForegroundColor Cyan
Write-Host "`n2. Deploy Phase 2 (compute resources):" -ForegroundColor White
Write-Host "   .\deploy-phase2.ps1 -KeyPairName <your-key-pair> -FoundationStackName $FoundationStackName" -ForegroundColor Cyan

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "PHASE 1 DEPLOYMENT COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green
