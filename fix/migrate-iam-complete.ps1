#!/usr/bin/env pwsh

# Complete IAM Migration Script
# This handles the full migration of IAM resources from foundation to dedicated stack

param(
    [Parameter(Mandatory=$false)]
    [string]$FoundationStackName = "devcloud-foundation",
    
    [Parameter(Mandatory=$false)]
    [string]$IAMStackName = "devcloud-iam-roles",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "Complete IAM Migration Process" -ForegroundColor Green
Write-Host "==============================" -ForegroundColor Green
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "IAM Stack: $IAMStackName" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Profile: $Profile" -ForegroundColor Yellow

# Step 1: Check dependent stacks
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "STEP 1: CHECKING DEPENDENT STACKS" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

$dependentStacks = @("devcloud-vpn-nat", "devcloud-private")
$existingStacks = @()

foreach ($stackName in $dependentStacks) {
    aws cloudformation describe-stacks --stack-name $stackName --region $Region --profile $Profile --output json 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $existingStacks += $stackName
        Write-Host "✓ Found dependent stack: $stackName" -ForegroundColor Yellow
    }
}

if ($existingStacks.Count -gt 0) {
    Write-Host "`nThe following stacks import IAM resources from the foundation stack:" -ForegroundColor Yellow
    $existingStacks | ForEach-Object { Write-Host "- $_" -ForegroundColor White }
    Write-Host "`nThese stacks need to be deleted before we can migrate IAM resources." -ForegroundColor Yellow
    Write-Host "They will be recreated after the IAM migration is complete." -ForegroundColor Yellow
    Write-Warning "This will temporarily shut down your compute resources."
    
    $confirm = Read-Host "Delete dependent stacks to proceed with migration? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Migration cancelled." -ForegroundColor Red
        exit 1
    }
    
    # Delete dependent stacks
    Write-Host "`nDeleting dependent stacks..." -ForegroundColor Blue
    foreach ($stackName in $existingStacks) {
        Write-Host "Deleting stack: $stackName" -ForegroundColor Blue
        aws cloudformation delete-stack --stack-name $stackName --region $Region --profile $Profile
        
        Write-Host "Waiting for stack deletion to complete..." -ForegroundColor Blue
        aws cloudformation wait stack-delete-complete --stack-name $stackName --region $Region --profile $Profile
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Stack $stackName deleted successfully" -ForegroundColor Green
        } else {
            Write-Error "Failed to delete stack $stackName"
            exit 1
        }
    }
} else {
    Write-Host "✓ No dependent stacks found" -ForegroundColor Green
}

# Step 2: Remove IAM from foundation stack
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "STEP 2: REMOVING IAM FROM FOUNDATION STACK" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Updating foundation stack to remove IAM resources..." -ForegroundColor Blue
    
    # Get current stack parameters
    $currentParams = aws cloudformation describe-stacks --stack-name $FoundationStackName --region $Region --profile $Profile --query 'Stacks[0].Parameters' --output json | ConvertFrom-Json
    
    $updateArgs = @(
        "cloudformation", "deploy",
        "--template-file", "foundation-infrastructure.yaml",
        "--stack-name", $FoundationStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--output", "table"
    )
    
    if ($currentParams) {
        $paramOverrides = @()
        foreach ($param in $currentParams) {
            $paramOverrides += "$($param.ParameterKey)=$($param.ParameterValue)"
        }
        $updateArgs += "--parameter-overrides"
        $updateArgs += $paramOverrides
    }
    
    & aws @updateArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Foundation stack updated successfully!" -ForegroundColor Green
    } else {
        Write-Error "Foundation stack update failed"
        exit 1
    }
} catch {
    Write-Error "Error updating foundation stack: $_"
    exit 1
}

# Step 3: Import IAM resources into new stack
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "STEP 3: IMPORTING IAM RESOURCES" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

Write-Host "Running IAM import script..." -ForegroundColor Blue
& ".\import-iam-roles.ps1" -FoundationStackName $FoundationStackName -IAMStackName $IAMStackName -Region $Region -Profile $Profile

if ($LASTEXITCODE -ne 0) {
    Write-Error "IAM import failed"
    exit 1
}

# Step 4: Instructions for redeploying compute stacks
Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "MIGRATION COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

if ($existingStacks.Count -gt 0) {
    Write-Host "`nNext Steps - Redeploy your compute stacks:" -ForegroundColor Yellow
    
    if ($existingStacks -contains "devcloud-vpn-nat") {
        Write-Host "`n1. Redeploy VPN/NAT instance:" -ForegroundColor White
        Write-Host "   .\deploy-phase2.ps1 -KeyPairName <your-key-pair> -FoundationStackName $FoundationStackName -IAMStackName $IAMStackName" -ForegroundColor Cyan
    }
    
    if ($existingStacks -contains "devcloud-private") {
        Write-Host "`n2. Redeploy private instance:" -ForegroundColor White
        Write-Host "   .\deploy-phase3.ps1 -KeyPairName <your-key-pair> -FoundationStackName $FoundationStackName -IAMStackName $IAMStackName" -ForegroundColor Cyan
    }
} else {
    Write-Host "`nIAM resources are now managed by the dedicated IAM stack." -ForegroundColor Green
    Write-Host "You can now deploy compute resources using the updated scripts." -ForegroundColor Green
}

Write-Host "`n✓ IAM migration from foundation stack to dedicated stack completed!" -ForegroundColor Green
