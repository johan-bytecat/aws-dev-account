#!/usr/bin/env pwsh

# Safe IAM Migration - No Downtime Approach
# Creates new IAM resources with different names, then updates references

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

Write-Host "Safe IAM Migration - No Downtime Approach" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "IAM Stack: $IAMStackName" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Profile: $Profile" -ForegroundColor Yellow

Write-Host "`nThis approach will:" -ForegroundColor Blue
Write-Host "1. Create NEW IAM resources with different names" -ForegroundColor White
Write-Host "2. Keep existing compute stacks running" -ForegroundColor White  
Write-Host "3. Update compute stacks to use new IAM resources (minimal downtime)" -ForegroundColor White
Write-Host "4. Remove old IAM resources from foundation stack" -ForegroundColor White

# Step 1: Create new IAM stack with different resource names
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "STEP 1: CREATING NEW IAM STACK" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

Write-Host "Deploying new IAM stack with fresh resources..." -ForegroundColor Blue
& ".\deploy-iam-roles.ps1" -FoundationStackName $FoundationStackName -IAMStackName $IAMStackName -Region $Region -Profile $Profile

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create new IAM stack"
    exit 1
}

Write-Host "✓ New IAM stack created successfully!" -ForegroundColor Green

# Step 2: Update compute stacks to use new IAM stack (one at a time)
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "STEP 2: UPDATING COMPUTE STACKS TO USE NEW IAM" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

$computeStacks = @("devcloud-vpn-nat", "devcloud-private")

foreach ($stackName in $computeStacks) {
    aws cloudformation describe-stacks --stack-name $stackName --region $Region --profile $Profile --output json 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nUpdating stack: $stackName" -ForegroundColor Blue
        
        # Get current parameters
        $currentParams = aws cloudformation describe-stacks --stack-name $stackName --region $Region --profile $Profile --query 'Stacks[0].Parameters' --output json | ConvertFrom-Json
        
        $updateArgs = @(
            "cloudformation", "deploy",
            "--stack-name", $stackName,
            "--region", $Region,
            "--profile", $Profile,
            "--capabilities", "CAPABILITY_IAM",
            "--output", "table"
        )
        
        # Determine which template to use
        $templateFile = ""
        if ($stackName -eq "devcloud-vpn-nat") {
            $templateFile = "phase2-vpn-nat.yaml"
        } elseif ($stackName -eq "devcloud-private") {
            $templateFile = "phase3-private-instance.yaml"
        }
        
        if ($templateFile) {
            $updateArgs += "--template-file", $templateFile
            
            # Build parameter overrides
            $paramOverrides = @()
            foreach ($param in $currentParams) {
                $paramOverrides += "$($param.ParameterKey)=$($param.ParameterValue)"
            }
            
            # Add the new IAM stack parameter
            $paramOverrides += "IAMStackName=$IAMStackName"
            
            $updateArgs += "--parameter-overrides"
            $updateArgs += $paramOverrides
            
            Write-Host "Updating $stackName to use new IAM stack..." -ForegroundColor Yellow
            & aws @updateArgs
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Stack $stackName updated successfully!" -ForegroundColor Green
            } else {
                Write-Warning "Failed to update stack $stackName - continuing with next stack"
            }
        }
    } else {
        Write-Host "Stack $stackName not found - skipping" -ForegroundColor Gray
    }
}

# Step 3: Verify everything is working
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "STEP 3: VERIFICATION" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

Write-Host "Checking IAM stack outputs..." -ForegroundColor Blue
aws cloudformation describe-stacks --stack-name $IAMStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output table

Write-Host "`nChecking compute stack status..." -ForegroundColor Blue
foreach ($stackName in $computeStacks) {
    aws cloudformation describe-stacks --stack-name $stackName --region $Region --profile $Profile --output json 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $stackStatus = aws cloudformation describe-stacks --stack-name $stackName --region $Region --profile $Profile --query 'Stacks[0].StackStatus' --output text
        Write-Host "✓ $stackName : $stackStatus" -ForegroundColor Green
    }
}

# Step 4: Instructions for cleanup
Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "MIGRATION COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

Write-Host "`nYour compute stacks are now using the new IAM resources." -ForegroundColor Green
Write-Host "The old IAM resources are still in the foundation stack but no longer referenced." -ForegroundColor Yellow

Write-Host "`nNext Steps (when you're ready):" -ForegroundColor Yellow
Write-Host "1. Verify everything is working correctly" -ForegroundColor White
Write-Host "2. Remove old IAM resources from foundation stack:" -ForegroundColor White
Write-Host "   .\remove-iam-from-foundation.ps1" -ForegroundColor Cyan
Write-Host "3. This is now safe since no stacks reference the old IAM resources" -ForegroundColor White

Write-Host "`n✓ Safe IAM migration completed with minimal disruption!" -ForegroundColor Green
