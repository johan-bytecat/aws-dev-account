#!/usr/bin/env pwsh

# Deploy new IAM roles with different names (safe migration)
# This creates NEW IAM resources that can coexist with existing ones

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

Write-Host "AWS DevCloud NEW IAM Roles Deployment (Safe Migration)" -ForegroundColor Green
Write-Host "=======================================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "IAM Stack: $IAMStackName" -ForegroundColor Yellow
Write-Host "Creating NEW IAM resources with -v2 suffix to avoid conflicts" -ForegroundColor Cyan

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
    exit 1
}

# Deploy NEW IAM Roles Stack
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "DEPLOYING NEW IAM ROLES AND POLICIES" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Deploying new IAM roles stack..." -ForegroundColor Blue
    
    $iamArgs = @(
        "cloudformation", "deploy",
        "--template-file", "iam-roles-new.yaml",
        "--stack-name", $IAMStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_NAMED_IAM",
        "--parameter-overrides", "FoundationStackName=$FoundationStackName", "PrivateHostedZoneId=$PrivateHostedZoneId",
        "--output", "table"
    )
    
    & aws @iamArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ NEW IAM roles stack deployed successfully!" -ForegroundColor Green
        
        # Get IAM stack outputs
        Write-Host "`nNew IAM Stack Outputs:" -ForegroundColor Blue
        aws cloudformation describe-stacks --stack-name $IAMStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output table
        
    } else {
        Write-Error "NEW IAM roles stack deployment failed"
        exit 1
    }
} catch {
    Write-Error "Error deploying NEW IAM roles stack: $_"
    exit 1
}

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "NEW IAM ROLES DEPLOYMENT COMPLETED!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

Write-Host "`nNew IAM resources created:" -ForegroundColor Yellow
Write-Host "- DevCloud-VPN-NAT-Role-v2" -ForegroundColor White
Write-Host "- DevCloud-Private-Instance-Role-v2" -ForegroundColor White  
Write-Host "- DevCloud-Instance-Management-Role-v2" -ForegroundColor White
Write-Host "- DevCloud-VPN-NAT-Role-v2 (instance profile)" -ForegroundColor White
Write-Host "- DevCloud-Private-Instance-Role-v2 (instance profile)" -ForegroundColor White

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. These new IAM resources can coexist with the old ones" -ForegroundColor White
Write-Host "2. Update your compute stacks to use the new IAM stack:" -ForegroundColor White
Write-Host "   .\update-compute-stacks.ps1" -ForegroundColor Cyan
Write-Host "3. Once verified, remove old IAM resources from foundation stack" -ForegroundColor White
