#!/usr/bin/env pwsh

# AWS DevCloud IAM Roles Deployment Script
# Deploys: IAM Roles, Instance Profiles, and Policies

param(
    [Parameter(Mandatory=$false)]
    [string]$FoundationStackName = "devcloud-foundation",
    
    [Parameter(Mandatory=$false)]
    [string]$IAMStackName = "devcloud-iam-roles",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateHostedZoneId = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud IAM Roles Deployment" -ForegroundColor Green
Write-Host "=================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "IAM Stack: $IAMStackName" -ForegroundColor Yellow
if ($PrivateHostedZoneId) {
    Write-Host "Private Hosted Zone ID: $PrivateHostedZoneId" -ForegroundColor Yellow
} else {
    Write-Host "Private Hosted Zone: Will use from foundation stack" -ForegroundColor Yellow
}

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "Deploying to AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

# Check if foundation stack exists
try {
    aws cloudformation describe-stacks --stack-name $FoundationStackName --region $Region --profile $Profile --output json | Out-Null
    Write-Host "✓ Foundation stack '$FoundationStackName' found" -ForegroundColor Green
} catch {
    Write-Error "Foundation stack '$FoundationStackName' not found. Please deploy foundation infrastructure first."
    Write-Host "Run: .\deploy-phase1.ps1" -ForegroundColor Cyan
    exit 1
}

# Deploy IAM Roles Stack
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "DEPLOYING IAM ROLES AND POLICIES" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Deploying IAM roles stack..." -ForegroundColor Blue
    
    $iamArgs = @(
        "cloudformation", "deploy",
        "--template-file", "iam-roles.yaml",
        "--stack-name", $IAMStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_NAMED_IAM",
        "--parameter-overrides", "FoundationStackName=$FoundationStackName", "PrivateHostedZoneId=$PrivateHostedZoneId",
        "--output", "table"
    )
    
    & aws @iamArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ IAM roles stack deployed successfully!" -ForegroundColor Green
        
        # Get IAM stack outputs
        Write-Host "`nIAM Stack Outputs:" -ForegroundColor Blue
        aws cloudformation describe-stacks --stack-name $IAMStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output table
        
    } else {
        Write-Error "IAM roles stack deployment failed"
        exit 1
    }
} catch {
    Write-Error "Error deploying IAM roles stack: $_"
    exit 1
}

# Next Steps
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "NEXT STEPS" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

Write-Host "`nIAM roles deployment completed successfully!" -ForegroundColor Green
Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Upload scripts to S3 bucket:" -ForegroundColor White
Write-Host "   .\upload-scripts.ps1 -StackName $FoundationStackName" -ForegroundColor Cyan
Write-Host "`n2. Deploy Phase 2 (compute resources):" -ForegroundColor White
Write-Host "   .\deploy-phase2.ps1 -KeyPairName <your-key-pair> -FoundationStackName $FoundationStackName -IAMStackName $IAMStackName" -ForegroundColor Cyan

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "IAM ROLES DEPLOYMENT COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green
