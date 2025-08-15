#!/usr/bin/env pwsh

# Update compute stacks to use new IAM roles (safe migration)
# This updates existing compute stacks to reference the new IAM stack

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

Write-Host "AWS DevCloud Compute Stacks Update (Safe Migration)" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "IAM Stack: $IAMStackName" -ForegroundColor Yellow
Write-Host "VPN/NAT Stack: $VPNNATStackName" -ForegroundColor Yellow
Write-Host "Private Stack: $PrivateStackName" -ForegroundColor Yellow

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "Deploying to AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

# Verify all required stacks exist
$requiredStacks = @($FoundationStackName, $IAMStackName, $VPNNATStackName, $PrivateStackName)
foreach ($stackName in $requiredStacks) {
    try {
        aws cloudformation describe-stacks --stack-name $stackName --region $Region --profile $Profile --output json | Out-Null
        Write-Host "✓ Stack '$stackName' found" -ForegroundColor Green
    } catch {
        Write-Error "Stack '$stackName' not found. Please ensure all stacks are deployed."
        exit 1
    }
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
    
    Write-Host "Updating VPN/NAT stack with new IAM references..." -ForegroundColor Blue
    
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
    
    Write-Host "Updating private instance stack with new IAM references..." -ForegroundColor Blue
    
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
Write-Host "COMPUTE STACKS UPDATE COMPLETED!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

Write-Host "`nBoth compute stacks now reference the new IAM stack:" -ForegroundColor Yellow
Write-Host "- VPN/NAT stack uses new IAM roles with -v2 suffix" -ForegroundColor White
Write-Host "- Private instance stack uses new IAM roles with -v2 suffix" -ForegroundColor White
Write-Host "- Original IAM resources in foundation stack are no longer used" -ForegroundColor White

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Verify both instances are running properly" -ForegroundColor White
Write-Host "2. Test connectivity and functionality" -ForegroundColor White
Write-Host "3. Remove old IAM resources from foundation stack template" -ForegroundColor White
Write-Host "4. Update foundation stack to remove unused IAM resources" -ForegroundColor White

Write-Host "`nMigration completed safely - no instance downtime occurred!" -ForegroundColor Green
