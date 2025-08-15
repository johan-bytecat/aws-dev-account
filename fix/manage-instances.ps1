#!/usr/bin/env pwsh

# Instance Management Script
# This script allows users to start/stop instances using the management role

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("start", "stop", "status")]
    [string]$Action,
    
    [Parameter(Mandatory=$true)]
    [ValidateSet("vpn-nat", "private", "both")]
    [string]$Instance,
    
    [Parameter(Mandatory=$false)]
    [string]$VPNNATStackName = "devcloud-vpn-nat",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateStackName = "devcloud-private",
    
    [Parameter(Mandatory=$false)]
    [string]$FoundationStackName = "devcloud-foundation",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev",
    
    [Parameter(Mandatory=$false)]
    [string]$RoleArn = ""
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud Instance Management" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow

# Get instance IDs from CloudFormation stack outputs
$vpnInstanceId = $null
$privateInstanceId = $null
$managementRoleArn = $null

try {
    # Get foundation stack outputs
    $foundationOutputs = aws cloudformation describe-stacks --stack-name $FoundationStackName --region $Region --query 'Stacks[0].Outputs' --output json | ConvertFrom-Json
    $managementRoleArn = ($foundationOutputs | Where-Object { $_.OutputKey -eq "InstanceManagementRoleArn" }).OutputValue
    
    # Get VPN/NAT instance ID if stack exists
    if ($Instance -eq "vpn-nat" -or $Instance -eq "both") {
        try {
            $vpnNatOutputs = aws cloudformation describe-stacks --stack-name $VPNNATStackName --region $Region --query 'Stacks[0].Outputs' --output json | ConvertFrom-Json
            $vpnInstanceId = ($vpnNatOutputs | Where-Object { $_.OutputKey -eq "VPNNATInstanceId" }).OutputValue
            Write-Host "VPN/NAT Instance ID: $vpnInstanceId" -ForegroundColor Yellow
        } catch {
            if ($Instance -eq "vpn-nat") {
                throw "VPN/NAT stack '$VPNNATStackName' not found or accessible"
            }
            Write-Warning "VPN/NAT stack '$VPNNATStackName' not found - skipping VPN/NAT instance"
        }
    }
    
    # Get Private instance ID if stack exists
    if ($Instance -eq "private" -or $Instance -eq "both") {
        try {
            $privateOutputs = aws cloudformation describe-stacks --stack-name $PrivateStackName --region $Region --query 'Stacks[0].Outputs' --output json | ConvertFrom-Json
            $privateInstanceId = ($privateOutputs | Where-Object { $_.OutputKey -eq "PrivateInstanceId" }).OutputValue
            Write-Host "Private Instance ID: $privateInstanceId" -ForegroundColor Yellow
        } catch {
            if ($Instance -eq "private") {
                throw "Private stack '$PrivateStackName' not found or accessible"
            }
            Write-Warning "Private stack '$PrivateStackName' not found - skipping private instance"
        }
    }
    
    if (!$managementRoleArn) {
        throw "Could not retrieve management role ARN from foundation stack"
    }
    
} catch {
    Write-Error "Error retrieving stack information: $_"
    exit 1
}

# Use provided role ARN or get from stack outputs
if ($RoleArn -eq "") {
    $RoleArn = $managementRoleArn
}

# Assume the management role
$sessionName = "DevCloud-Management-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "Assuming role: $RoleArn" -ForegroundColor Blue

try {
    $roleCredentials = aws sts assume-role --role-arn $RoleArn --role-session-name $sessionName --output json | ConvertFrom-Json
    
    $env:AWS_ACCESS_KEY_ID = $roleCredentials.Credentials.AccessKeyId
    $env:AWS_SECRET_ACCESS_KEY = $roleCredentials.Credentials.SecretAccessKey
    $env:AWS_SESSION_TOKEN = $roleCredentials.Credentials.SessionToken
    
} catch {
    Write-Error "Error assuming role: $_"
    exit 1
}

# Determine which instances to act on
$instanceIds = @()
switch ($Instance) {
    "vpn-nat" { 
        if ($vpnInstanceId) { 
            $instanceIds += $vpnInstanceId 
        } else {
            Write-Error "VPN/NAT instance not available"
            exit 1
        }
    }
    "private" { 
        if ($privateInstanceId) { 
            $instanceIds += $privateInstanceId 
        } else {
            Write-Error "Private instance not available"
            exit 1
        }
    }
    "both" { 
        if ($vpnInstanceId) { $instanceIds += $vpnInstanceId }
        if ($privateInstanceId) { $instanceIds += $privateInstanceId }
        if ($instanceIds.Count -eq 0) {
            Write-Error "No instances available"
            exit 1
        }
    }
}

# Execute the action
switch ($Action) {
    "start" {
        Write-Host "Starting instances..." -ForegroundColor Green
        foreach ($id in $instanceIds) {
            Write-Host "Starting instance: $id"
            aws ec2 start-instances --instance-ids $id --region $Region
        }
    }
    "stop" {
        Write-Host "Stopping instances..." -ForegroundColor Red
        foreach ($id in $instanceIds) {
            Write-Host "Stopping instance: $id"
            aws ec2 stop-instances --instance-ids $id --region $Region
        }
    }
    "status" {
        Write-Host "Checking instance status..." -ForegroundColor Blue
        aws ec2 describe-instances --instance-ids $instanceIds --region $Region --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' --output table
    }
}

# Clean up environment variables
Remove-Item Env:AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
Remove-Item Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
Remove-Item Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue

Write-Host "Operation completed!" -ForegroundColor Green
