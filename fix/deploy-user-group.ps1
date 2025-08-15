#!/usr/bin/env pwsh

# Deploy user group for instance management
# Run this after the main infrastructure is deployed

param(
    [Parameter(Mandatory=$false)]
    [string]$IAMStackName = "devcloud-iam-roles",
    
    [Parameter(Mandatory=$false)]
    [string]$UserGroupStackName = "devcloud-user-group",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string[]]$UserNames = @()
)

Write-Host "Deploying DevCloud User Group..." -ForegroundColor Green

# Check if IAM stack exists
try {
    aws cloudformation describe-stacks --stack-name $IAMStackName --region $Region --output table | Out-Null
    Write-Host "✓ IAM stack '$IAMStackName' found" -ForegroundColor Green
} catch {
    Write-Error "IAM stack '$IAMStackName' not found in region $Region"
    Write-Host "Deploy IAM roles first with: .\deploy-iam-roles.ps1" -ForegroundColor Yellow
    exit 1
}

# Prepare parameters
$parameters = @(
    "ParameterKey=IAMStackName,ParameterValue=$IAMStackName"
)

if ($UserNames.Length -gt 0) {
    $userList = $UserNames -join ','
    $parameters += "ParameterKey=UserNames,ParameterValue=$userList"
    Write-Host "Adding users to group: $userList" -ForegroundColor Yellow
}

# Deploy the user group stack
try {
    aws cloudformation deploy `
        --template-file user-group.yaml `
        --stack-name $UserGroupStackName `
        --region $Region `
        --capabilities CAPABILITY_IAM `
        --parameters $parameters `
        --output table

    if ($LASTEXITCODE -eq 0) {
        Write-Host "User group deployed successfully!" -ForegroundColor Green
        
        # Get stack outputs
        Write-Host "`nStack Outputs:" -ForegroundColor Blue
        aws cloudformation describe-stacks --stack-name $UserGroupStackName --region $Region --query 'Stacks[0].Outputs' --output table
        
        Write-Host "`nNext Steps:" -ForegroundColor Yellow
        Write-Host "1. Add IAM users to the 'DevCloud-Instance-Managers' group" -ForegroundColor White
        Write-Host "2. Users can now use the manage-instances.ps1 script" -ForegroundColor White
        Write-Host "3. Example: .\manage-instances.ps1 -Action start -Instance both" -ForegroundColor White
        
    } else {
        Write-Error "User group deployment failed"
        exit 1
    }
} catch {
    Write-Error "Error deploying user group: $_"
    exit 1
}
