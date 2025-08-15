#!/usr/bin/env pwsh

# Manual IAM Profile Migration - Zero Downtime Approach
# This manually updates the IAM instance profiles on running instances

param(
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

Write-Host "AWS DevCloud Manual IAM Migration (Zero Downtime)" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "IAM Stack: $IAMStackName" -ForegroundColor Yellow

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "Working with AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

# Get new IAM instance profiles from IAM stack
Write-Host "`nGetting new IAM instance profiles..." -ForegroundColor Blue

try {
    $iamOutputs = aws cloudformation describe-stacks --stack-name $IAMStackName --region $Region --profile $Profile --output json | ConvertFrom-Json
    $vpnNatProfile = ($iamOutputs.Stacks[0].Outputs | Where-Object { $_.OutputKey -eq "VPNNATInstanceProfileName" }).OutputValue
    $privateProfile = ($iamOutputs.Stacks[0].Outputs | Where-Object { $_.OutputKey -eq "PrivateInstanceProfileName" }).OutputValue
    
    Write-Host "New VPN/NAT Instance Profile: $vpnNatProfile" -ForegroundColor Cyan
    Write-Host "New Private Instance Profile: $privateProfile" -ForegroundColor Cyan
} catch {
    Write-Error "Failed to get IAM stack outputs. Ensure IAM stack is deployed."
    exit 1
}

# Get current instances
Write-Host "`nFinding current instances..." -ForegroundColor Blue

# Get VPN/NAT instance
try {
    $vpnNatInstance = aws ec2 describe-instances --region $Region --profile $Profile --filters "Name=tag:Name,Values=DevCloud-VPN-NAT-Gateway" --query "Reservations[0].Instances[0]" --output json | ConvertFrom-Json
    $vpnNatInstanceId = $vpnNatInstance.InstanceId
    $vpnNatCurrentProfile = $vpnNatInstance.IamInstanceProfile.Arn.Split('/')[-1]
    
    # Get the association ID
    $vpnNatAssociationId = aws ec2 describe-iam-instance-profile-associations --region $Region --profile $Profile --filters "Name=instance-id,Values=$vpnNatInstanceId" --query "IamInstanceProfileAssociations[0].AssociationId" --output text
    
    Write-Host "VPN/NAT Instance ID: $vpnNatInstanceId" -ForegroundColor White
    Write-Host "Current Profile: $vpnNatCurrentProfile" -ForegroundColor White
    Write-Host "Association ID: $vpnNatAssociationId" -ForegroundColor White
    Write-Host "Target Profile: $vpnNatProfile" -ForegroundColor White
} catch {
    Write-Error "Failed to find VPN/NAT instance"
    exit 1
}

# Get Private instance (try different possible names)
$privateInstanceNames = @("DevCloud-Private-Instance", "DevCloud-Kite-Server")
$privateInstance = $null

foreach ($name in $privateInstanceNames) {
    try {
        $result = aws ec2 describe-instances --region $Region --profile $Profile --filters "Name=tag:Name,Values=$name" --query "Reservations[0].Instances[0]" --output json | ConvertFrom-Json
        if ($result -and $result.InstanceId) {
            $privateInstance = $result
            Write-Host "Found private instance with name: $name" -ForegroundColor Green
            break
        }
    } catch {
        # Continue to next name
    }
}

if ($privateInstance) {
    $privateInstanceId = $privateInstance.InstanceId
    $privateCurrentProfile = $privateInstance.IamInstanceProfile.Arn.Split('/')[-1]
    
    # Get the association ID  
    $privateAssociationId = aws ec2 describe-iam-instance-profile-associations --region $Region --profile $Profile --filters "Name=instance-id,Values=$privateInstanceId" --query "IamInstanceProfileAssociations[0].AssociationId" --output text
    
    Write-Host "Private Instance ID: $privateInstanceId" -ForegroundColor White
    Write-Host "Current Profile: $privateCurrentProfile" -ForegroundColor White
    Write-Host "Association ID: $privateAssociationId" -ForegroundColor White
    Write-Host "Target Profile: $privateProfile" -ForegroundColor White
} else {
    Write-Warning "No private instance found with expected names. Will only migrate VPN/NAT instance."
    $privateInstance = $null
}

# Confirm migration
Write-Host "`n" + "="*60 -ForegroundColor Yellow
Write-Host "MIGRATION PLAN" -ForegroundColor Yellow
Write-Host "="*60 -ForegroundColor Yellow
Write-Host "1. Replace IAM instance profile on VPN/NAT instance (no restart)" -ForegroundColor White
Write-Host "2. Replace IAM instance profile on Private instance (no restart)" -ForegroundColor White
Write-Host "3. Both instances will continue running with new IAM roles" -ForegroundColor White
Write-Host "`nThis operation will NOT restart or replace the instances!" -ForegroundColor Green

$confirmation = Read-Host "`nProceed with manual IAM migration? (y/N)"
if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
    Write-Host "Migration cancelled by user." -ForegroundColor Yellow
    exit 0
}

# Migrate VPN/NAT Instance Profile
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "MIGRATING VPN/NAT INSTANCE PROFILE" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Replacing IAM instance profile on VPN/NAT instance..." -ForegroundColor Blue
    
    # Replace the instance profile
    aws ec2 replace-iam-instance-profile-association --region $Region --profile $Profile --iam-instance-profile Name=$vpnNatProfile --association-id $vpnNatAssociationId --output table
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ VPN/NAT instance profile updated successfully!" -ForegroundColor Green
        
        # Verify the change
        Start-Sleep 2
        $updatedInstance = aws ec2 describe-instances --instance-ids $vpnNatInstanceId --region $Region --profile $Profile --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" --output text
        Write-Host "Verified new profile: $($updatedInstance.Split('/')[-1])" -ForegroundColor Green
    } else {
        Write-Error "Failed to update VPN/NAT instance profile"
        exit 1
    }
} catch {
    Write-Error "Error migrating VPN/NAT instance profile: $_"
    exit 1
}

# Migrate Private Instance Profile (if found)
if ($privateInstance) {
    Write-Host "`n" + "="*60 -ForegroundColor Blue
    Write-Host "MIGRATING PRIVATE INSTANCE PROFILE" -ForegroundColor Blue
    Write-Host "="*60 -ForegroundColor Blue

    try {
        Write-Host "Replacing IAM instance profile on Private instance..." -ForegroundColor Blue
        
        # Replace the instance profile
        aws ec2 replace-iam-instance-profile-association --region $Region --profile $Profile --iam-instance-profile Name=$privateProfile --association-id $privateAssociationId --output table
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Private instance profile updated successfully!" -ForegroundColor Green
            
            # Verify the change
            Start-Sleep 2
            $updatedInstance = aws ec2 describe-instances --instance-ids $privateInstanceId --region $Region --profile $Profile --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" --output text
            Write-Host "Verified new profile: $($updatedInstance.Split('/')[-1])" -ForegroundColor Green
        } else {
            Write-Error "Failed to update Private instance profile"
            exit 1
        }
    } catch {
        Write-Error "Error migrating Private instance profile: $_"
        exit 1
    }
} else {
    Write-Host "`nSkipping private instance migration (not found)" -ForegroundColor Yellow
}

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "MANUAL IAM MIGRATION COMPLETED!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

Write-Host "`nBoth instances now use the new IAM roles:" -ForegroundColor Yellow
Write-Host "- VPN/NAT: $vpnNatProfile" -ForegroundColor White
if ($privateInstance) {
    Write-Host "- Private: $privateProfile" -ForegroundColor White
} else {
    Write-Host "- Private: (not found, skipped)" -ForegroundColor Yellow
}
Write-Host "- No instance restarts occurred" -ForegroundColor White
Write-Host "- No downtime occurred" -ForegroundColor White

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Test that both instances work properly with new IAM roles" -ForegroundColor White
Write-Host "2. Update CloudFormation templates to reflect the new IAM configuration" -ForegroundColor White
Write-Host "3. Run update-compute-stacks-drift.ps1 to sync CloudFormation state" -ForegroundColor White

Write-Host "`nZero-downtime migration completed successfully!" -ForegroundColor Green
