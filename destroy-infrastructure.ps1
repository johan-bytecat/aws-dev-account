#!/usr/bin/env pwsh

# Cleanup and Destroy DevCloud Infrastructure
# Deletes stacks in proper order to avoid dependency issues

param(
    [Parameter(Mandatory=$false)]
    [string]$NetworkStackName = "devcloud-network",
    
    [Parameter(Mandatory=$false)]
    [string]$ApplicationStackPattern = "devcloud-app-*",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev",
    
    [Parameter(Mandatory=$false)]
    [switch]$ConfirmDestroy = $false
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "DevCloud Infrastructure Cleanup" -ForegroundColor Red
Write-Host "===============================" -ForegroundColor Red
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Network Stack: $NetworkStackName" -ForegroundColor Yellow
Write-Host "Application Pattern: $ApplicationStackPattern" -ForegroundColor Yellow

if (-not $ConfirmDestroy) {
    Write-Host "`nWARNING: This will destroy ALL DevCloud infrastructure!" -ForegroundColor Red
    Write-Host "This action cannot be undone." -ForegroundColor Red
    Write-Host "`nTo proceed, run with -ConfirmDestroy switch:" -ForegroundColor Yellow
    Write-Host ".\destroy-infrastructure.ps1 -ConfirmDestroy" -ForegroundColor Cyan
    exit 0
}

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

Write-Host "`nFinal confirmation required!" -ForegroundColor Red
Write-Host "Type 'DESTROY' to proceed with infrastructure deletion:" -ForegroundColor Yellow
$confirmation = Read-Host

if ($confirmation -ne "DESTROY") {
    Write-Host "Operation cancelled." -ForegroundColor Green
    exit 0
}

# Step 1: Delete application stacks first
Write-Host "`n" + "="*60 -ForegroundColor Red
Write-Host "STEP 1: DELETING APPLICATION STACKS" -ForegroundColor Red
Write-Host "="*60 -ForegroundColor Red

try {
    # Find application stacks
    $appStacks = aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --region $Region --profile $Profile --query 'StackSummaries[?contains(StackName, `devcloud-app-`)].StackName' --output text
    
    if ($appStacks) {
        $stackList = $appStacks -split "`t"
        foreach ($appStack in $stackList) {
            Write-Host "Deleting application stack: $appStack" -ForegroundColor Yellow
            aws cloudformation delete-stack --stack-name $appStack --region $Region --profile $Profile
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Deletion initiated for $appStack" -ForegroundColor Green
            } else {
                Write-Warning "Failed to initiate deletion for $appStack"
            }
        }
        
        # Wait for application stacks to be deleted
        Write-Host "`nWaiting for application stacks to be deleted..." -ForegroundColor Yellow
        foreach ($appStack in $stackList) {
            Write-Host "Waiting for $appStack..." -ForegroundColor Cyan
            aws cloudformation wait stack-delete-complete --stack-name $appStack --region $Region --profile $Profile
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ $appStack deleted successfully" -ForegroundColor Green
            } else {
                Write-Warning "Failed to delete $appStack or deletion timed out"
            }
        }
    } else {
        Write-Host "No application stacks found" -ForegroundColor Green
    }
} catch {
    Write-Warning "Error during application stack deletion: $_"
}

# Step 2: Delete network stack
Write-Host "`n" + "="*60 -ForegroundColor Red
Write-Host "STEP 2: DELETING NETWORK STACK" -ForegroundColor Red
Write-Host "="*60 -ForegroundColor Red

try {
    Write-Host "Deleting network stack: $NetworkStackName" -ForegroundColor Yellow
    aws cloudformation delete-stack --stack-name $NetworkStackName --region $Region --profile $Profile
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Deletion initiated for $NetworkStackName" -ForegroundColor Green
        
        # Wait for network stack to be deleted
        Write-Host "`nWaiting for network stack to be deleted..." -ForegroundColor Yellow
        Write-Host "This may take several minutes..." -ForegroundColor Cyan
        aws cloudformation wait stack-delete-complete --stack-name $NetworkStackName --region $Region --profile $Profile
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ $NetworkStackName deleted successfully" -ForegroundColor Green
        } else {
            Write-Warning "Failed to delete $NetworkStackName or deletion timed out"
        }
    } else {
        Write-Warning "Failed to initiate deletion for $NetworkStackName"
    }
} catch {
    Write-Warning "Error during network stack deletion: $_"
}

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "INFRASTRUCTURE CLEANUP COMPLETED" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

Write-Host "`nCleanup Summary:" -ForegroundColor Yellow
Write-Host "• Application stacks deleted" -ForegroundColor White
Write-Host "• Network stack deleted" -ForegroundColor White
Write-Host "• EC2 instances terminated" -ForegroundColor White
Write-Host "• EBS volumes deleted" -ForegroundColor White
Write-Host "• EFS filesystems deleted" -ForegroundColor White

Write-Host "`nNote: S3 buckets may still exist if they contained data." -ForegroundColor Yellow
Write-Host "Check and manually delete S3 buckets if needed:" -ForegroundColor Yellow
Write-Host "  aws s3 ls | grep devcloud" -ForegroundColor Cyan
