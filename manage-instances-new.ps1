#!/usr/bin/env pwsh

# Instance Management Script for DevCloud Infrastructure
# Manages EC2 instances across network and application stacks

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("start", "stop", "status", "restart")]
    [string]$Action,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("vpn-nat", "app", "all")]
    [string]$Instance = "all",
    
    [Parameter(Mandatory=$false)]
    [string]$NetworkStackName = "devcloud-network",
    
    [Parameter(Mandatory=$false)]
    [string]$ApplicationStackName = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "DevCloud Instance Management" -ForegroundColor Green
Write-Host "============================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Action: $Action" -ForegroundColor Yellow
Write-Host "Instance(s): $Instance" -ForegroundColor Yellow

# Function to get instance information from stack
function Get-InstanceFromStack {
    param(
        [string]$StackName,
        [string]$OutputKey
    )
    
    try {
        $outputs = aws cloudformation describe-stacks --stack-name $StackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output json | ConvertFrom-Json
        $instanceId = ($outputs | Where-Object { $_.OutputKey -eq $OutputKey }).OutputValue
        return $instanceId
    } catch {
        return $null
    }
}

# Function to get instance status
function Get-InstanceStatus {
    param(
        [string]$InstanceId
    )
    
    try {
        $status = aws ec2 describe-instances --instance-ids $InstanceId --region $Region --profile $Profile --query 'Reservations[0].Instances[0].State.Name' --output text
        return $status
    } catch {
        return "unknown"
    }
}

# Function to manage instance
function Manage-Instance {
    param(
        [string]$InstanceId,
        [string]$InstanceName,
        [string]$Action
    )
    
    if ([string]::IsNullOrEmpty($InstanceId)) {
        Write-Warning "Could not find instance ID for $InstanceName"
        return
    }
    
    $currentStatus = Get-InstanceStatus -InstanceId $InstanceId
    Write-Host "`n$InstanceName ($InstanceId):" -ForegroundColor Cyan
    Write-Host "  Current status: $currentStatus" -ForegroundColor White
    
    switch ($Action) {
        "status" {
            # Status already displayed above
            if ($currentStatus -eq "running") {
                # Get additional info for running instances
                try {
                    $instanceInfo = aws ec2 describe-instances --instance-ids $InstanceId --region $Region --profile $Profile --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress,InstanceType]' --output text
                    $publicIp, $privateIp, $instanceType = $instanceInfo -split "`t"
                    Write-Host "  Public IP: $publicIp" -ForegroundColor White
                    Write-Host "  Private IP: $privateIp" -ForegroundColor White
                    Write-Host "  Instance Type: $instanceType" -ForegroundColor White
                } catch {
                    Write-Host "  Could not retrieve additional instance details" -ForegroundColor Yellow
                }
            }
        }
        "start" {
            if ($currentStatus -eq "running") {
                Write-Host "  Already running" -ForegroundColor Green
            } elseif ($currentStatus -eq "stopped") {
                Write-Host "  Starting instance..." -ForegroundColor Yellow
                aws ec2 start-instances --instance-ids $InstanceId --region $Region --profile $Profile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ Start command sent successfully" -ForegroundColor Green
                } else {
                    Write-Host "  ✗ Failed to start instance" -ForegroundColor Red
                }
            } else {
                Write-Host "  Cannot start instance in state: $currentStatus" -ForegroundColor Yellow
            }
        }
        "stop" {
            if ($currentStatus -eq "stopped") {
                Write-Host "  Already stopped" -ForegroundColor Green
            } elseif ($currentStatus -eq "running") {
                Write-Host "  Stopping instance..." -ForegroundColor Yellow
                aws ec2 stop-instances --instance-ids $InstanceId --region $Region --profile $Profile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ Stop command sent successfully" -ForegroundColor Green
                } else {
                    Write-Host "  ✗ Failed to stop instance" -ForegroundColor Red
                }
            } else {
                Write-Host "  Cannot stop instance in state: $currentStatus" -ForegroundColor Yellow
            }
        }
        "restart" {
            if ($currentStatus -eq "running") {
                Write-Host "  Restarting instance..." -ForegroundColor Yellow
                aws ec2 reboot-instances --instance-ids $InstanceId --region $Region --profile $Profile | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ Restart command sent successfully" -ForegroundColor Green
                } else {
                    Write-Host "  ✗ Failed to restart instance" -ForegroundColor Red
                }
            } else {
                Write-Host "  Cannot restart instance in state: $currentStatus" -ForegroundColor Yellow
            }
        }
    }
}

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

# Get VPN/NAT instance from network stack
$vpnNatInstanceId = $null
if ($Instance -eq "vpn-nat" -or $Instance -eq "all") {
    Write-Host "`nChecking network stack: $NetworkStackName" -ForegroundColor Blue
    $vpnNatInstanceId = Get-InstanceFromStack -StackName $NetworkStackName -OutputKey "VPNNATInstanceId"
    
    if ($vpnNatInstanceId) {
        Manage-Instance -InstanceId $vpnNatInstanceId -InstanceName "VPN/NAT Gateway" -Action $Action
    } else {
        Write-Warning "Could not find VPN/NAT instance in network stack: $NetworkStackName"
    }
}

# Get application instance(s)
if ($Instance -eq "app" -or $Instance -eq "all") {
    if ([string]::IsNullOrEmpty($ApplicationStackName)) {
        # Try to find application stacks automatically
        Write-Host "`nLooking for application stacks..." -ForegroundColor Blue
        try {
            $stacks = aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --region $Region --profile $Profile --query 'StackSummaries[?contains(StackName, `devcloud-app-`)].StackName' --output text
            
            if ($stacks) {
                $stackList = $stacks -split "`t"
                foreach ($appStack in $stackList) {
                    Write-Host "`nChecking application stack: $appStack" -ForegroundColor Blue
                    $appInstanceId = Get-InstanceFromStack -StackName $appStack -OutputKey "PrivateInstanceId"
                    
                    if ($appInstanceId) {
                        Manage-Instance -InstanceId $appInstanceId -InstanceName "Application Instance ($appStack)" -Action $Action
                    }
                }
            } else {
                Write-Warning "No application stacks found with pattern 'devcloud-app-*'"
            }
        } catch {
            Write-Warning "Could not search for application stacks automatically"
        }
    } else {
        Write-Host "`nChecking application stack: $ApplicationStackName" -ForegroundColor Blue
        $appInstanceId = Get-InstanceFromStack -StackName $ApplicationStackName -OutputKey "PrivateInstanceId"
        
        if ($appInstanceId) {
            Manage-Instance -InstanceId $appInstanceId -InstanceName "Application Instance" -Action $Action
        } else {
            Write-Warning "Could not find application instance in stack: $ApplicationStackName"
        }
    }
}

Write-Host "`n" + "="*50 -ForegroundColor Blue
Write-Host "INSTANCE MANAGEMENT COMPLETED" -ForegroundColor Green
Write-Host "="*50 -ForegroundColor Blue

if ($Action -ne "status") {
    Write-Host "`nNote: Instance state changes may take a few minutes to complete." -ForegroundColor Yellow
    Write-Host "Run with -Action status to check current state." -ForegroundColor Yellow
}
