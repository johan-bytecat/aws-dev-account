#!/usr/bin/env pwsh

# Fix compute stacks after manual IAM migration
# This updates the CloudFormation stacks to match the current IAM configuration

param(
    [Parameter(Mandatory=$false)]
    [string]$FoundationStackName = "devcloud-foundation",
    
    [Parameter(Mandatory=$false)]
    [string]$IAMStackName = "devcloud-iam-roles",
    
    [Parameter(Mandatory=$false)]
    [string]$VPNNATStackName = "devcloud-vpn-nat",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateStackName = "devcloud-private",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud Compute Stacks Fix (Post Manual IAM Migration)" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "IAM Stack: $IAMStackName" -ForegroundColor Yellow
Write-Host "VPN/NAT Stack: $VPNNATStackName" -ForegroundColor Yellow
Write-Host "Private Stack: $PrivateStackName" -ForegroundColor Yellow

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "Working with AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

# Function to get current stack parameters
function Get-StackParameters {
    param([string]$StackName)
    
    $stackInfo = aws cloudformation describe-stacks --stack-name $StackName --region $Region --profile $Profile --output json | ConvertFrom-Json
    return $stackInfo.Stacks[0].Parameters
}

# Update VPN/NAT Stack
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "UPDATING VPN/NAT STACK" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Getting current VPN/NAT stack parameters..." -ForegroundColor Blue
    $vpnNatParams = Get-StackParameters -StackName $VPNNATStackName
    
    # Build parameter overrides array
    $paramOverrides = @()
    foreach ($param in $vpnNatParams) {
        if ($param.ParameterKey -eq "IAMStackName") {
            $paramOverrides += "$($param.ParameterKey)=$IAMStackName"
        } else {
            $paramOverrides += "$($param.ParameterKey)=$($param.ParameterValue)"
        }
    }
    
    # Add IAMStackName if it doesn't exist
    if (-not ($vpnNatParams | Where-Object { $_.ParameterKey -eq "IAMStackName" })) {
        $paramOverrides += "IAMStackName=$IAMStackName"
    }
    
    Write-Host "Current parameters:" -ForegroundColor Cyan
    foreach ($override in $paramOverrides) {
        Write-Host "  $override" -ForegroundColor White
    }
    
    Write-Host "`nDeploying VPN/NAT stack with IAM stack reference..." -ForegroundColor Blue
    
    $vpnNatArgs = @(
        "cloudformation", "deploy",
        "--template-file", "phase2-vpn-nat.yaml",
        "--stack-name", $VPNNATStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_IAM",
        "--parameter-overrides"
    ) + $paramOverrides + @("--output", "table")
    
    & aws @vpnNatArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ VPN/NAT stack updated successfully!" -ForegroundColor Green
    } else {
        Write-Error "VPN/NAT stack update failed"
        exit 1
    }
} catch {
    Write-Error "Error updating VPN/NAT stack: $_"
    exit 1
}

# Update Private Instance Stack  
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "UPDATING PRIVATE INSTANCE STACK" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Getting current private stack parameters..." -ForegroundColor Blue
    $privateParams = Get-StackParameters -StackName $PrivateStackName
    
    # Build parameter overrides array
    $paramOverrides = @()
    foreach ($param in $privateParams) {
        if ($param.ParameterKey -eq "IAMStackName") {
            $paramOverrides += "$($param.ParameterKey)=$IAMStackName"
        } else {
            $paramOverrides += "$($param.ParameterKey)=$($param.ParameterValue)"
        }
    }
    
    # Add IAMStackName if it doesn't exist
    if (-not ($privateParams | Where-Object { $_.ParameterKey -eq "IAMStackName" })) {
        $paramOverrides += "IAMStackName=$IAMStackName"
    }
    
    Write-Host "Current parameters:" -ForegroundColor Cyan
    foreach ($override in $paramOverrides) {
        Write-Host "  $override" -ForegroundColor White
    }
    
    Write-Host "`nDeploying private instance stack with IAM stack reference..." -ForegroundColor Blue
    
    $privateArgs = @(
        "cloudformation", "deploy",
        "--template-file", "phase3-private-instance.yaml",
        "--stack-name", $PrivateStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_IAM",
        "--parameter-overrides"
    ) + $paramOverrides + @("--output", "table")
    
    & aws @privateArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Private instance stack updated successfully!" -ForegroundColor Green
    } else {
        Write-Error "Private instance stack update failed"
        exit 1
    }
} catch {
    Write-Error "Error updating private instance stack: $_"
    exit 1
}

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "COMPUTE STACKS FIX COMPLETED!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

Write-Host "`nResult:" -ForegroundColor Yellow
Write-Host "✓ Both compute stacks now properly reference the IAM stack" -ForegroundColor Green
Write-Host "✓ Instances already have correct IAM roles (manual migration)" -ForegroundColor Green
Write-Host "✓ CloudFormation state now matches actual infrastructure" -ForegroundColor Green

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Verify both instances are working correctly" -ForegroundColor White
Write-Host "2. Test connectivity and functionality" -ForegroundColor White  
Write-Host "3. Clean up old IAM resources from foundation stack (optional)" -ForegroundColor White

Write-Host "`nIAM Migration Complete! 🎉" -ForegroundColor Green
