#!/usr/bin/env pwsh

# Remove IAM resources from foundation stack
# This creates an updated foundation template without IAM resources and updates the stack

param(
    [Parameter(Mandatory=$false)]
    [string]$FoundationStackName = "devcloud-foundation",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "Removing IAM Resources from Foundation Stack" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Profile: $Profile" -ForegroundColor Yellow

# Check if foundation stack exists
try {
    aws cloudformation describe-stacks --stack-name $FoundationStackName --region $Region --profile $Profile --output json | Out-Null
    Write-Host "✓ Foundation stack '$FoundationStackName' found" -ForegroundColor Green
} catch {
    Write-Error "Foundation stack '$FoundationStackName' not found."
    exit 1
}

# Show current IAM resources in foundation stack
Write-Host "`nCurrent IAM resources in foundation stack:" -ForegroundColor Blue
aws cloudformation describe-stack-resources --stack-name $FoundationStackName --region $Region --profile $Profile --query 'StackResources[?contains(ResourceType, `IAM`)].[LogicalResourceId,ResourceType,PhysicalResourceId]' --output table

Write-Host "`nThis will update the foundation stack to remove all IAM resources." -ForegroundColor Yellow
Write-Host "The IAM resources will remain in AWS but no longer be managed by the foundation stack." -ForegroundColor Yellow
Write-Warning "This is irreversible for this stack. Continue only if you're sure."
Read-Host "Press Enter to continue or Ctrl+C to cancel"

# Update foundation stack without IAM resources
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "UPDATING FOUNDATION STACK (REMOVING IAM RESOURCES)" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Updating foundation stack to remove IAM resources..." -ForegroundColor Blue
    
    $updateArgs = @(
        "cloudformation", "deploy",
        "--template-file", "foundation-infrastructure.yaml",
        "--stack-name", $FoundationStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--output", "table"
    )
    
    # Get current stack parameters
    $currentParams = aws cloudformation describe-stacks --stack-name $FoundationStackName --region $Region --profile $Profile --query 'Stacks[0].Parameters' --output json | ConvertFrom-Json
    
    if ($currentParams) {
        Write-Host "Using current stack parameters..." -ForegroundColor Blue
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
        
        # Verify IAM resources are no longer in stack
        Write-Host "`nVerifying IAM resources removed from stack..." -ForegroundColor Blue
        $remainingIAM = aws cloudformation describe-stack-resources --stack-name $FoundationStackName --region $Region --profile $Profile --query 'StackResources[?contains(ResourceType, `IAM`)]' --output json | ConvertFrom-Json
        
        if ($remainingIAM -and $remainingIAM.Count -gt 0) {
            Write-Warning "Some IAM resources still remain in the stack:"
            $remainingIAM | ForEach-Object { Write-Host "- $($_.LogicalResourceId)" -ForegroundColor Yellow }
        } else {
            Write-Host "✓ All IAM resources successfully removed from foundation stack" -ForegroundColor Green
        }
        
        # Show updated foundation stack outputs
        Write-Host "`nUpdated Foundation Stack Outputs:" -ForegroundColor Blue
        aws cloudformation describe-stacks --stack-name $FoundationStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output table
        
    } else {
        Write-Error "Foundation stack update failed"
        exit 1
    }
} catch {
    Write-Error "Error updating foundation stack: $_"
    exit 1
}

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "IAM RESOURCES REMOVED FROM FOUNDATION STACK" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Import IAM resources into dedicated stack:" -ForegroundColor White
Write-Host "   .\import-iam-roles.ps1" -ForegroundColor Cyan
Write-Host "`n2. Or deploy fresh IAM stack:" -ForegroundColor White
Write-Host "   .\deploy-iam-roles.ps1" -ForegroundColor Cyan
