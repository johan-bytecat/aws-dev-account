#!/usr/bin/env pwsh

# AWS DevCloud Network Infrastructure Change Set Script
# Creates a change set for devcloud network stack, describes it, and optionally executes or deletes it

param(
    [Parameter(Mandatory=$true)]
    [string]$KeyPairName,
    
    [Parameter(Mandatory=$false)]
    [string]$NetworkStackName = "devcloud-network",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$DomainName = "devcloud.bytecat.co.za",
    
    [Parameter(Mandatory=$false)]
    [string]$VpcCidr = "172.16.0.0/16",
    
    [Parameter(Mandatory=$false)]
    [string]$PublicSubnetCidr = "172.16.1.0/24",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateSubnetCidr = "172.16.2.0/24",
    
    [Parameter(Mandatory=$false)]
    [string]$SecondPrivateSubnetCidr = "172.16.3.0/24",
    
    [Parameter(Mandatory=$false)]
    [string]$VPNNATPrivateIP = "172.16.1.100",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateHostedZoneId = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev",
    
    [Parameter(Mandatory=$false)]
    [bool]$Execute = $false
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

$ChangeSetName = "devcloud-network-update-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

Write-Host "AWS DevCloud Network Infrastructure Change Set" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Network Stack: $NetworkStackName" -ForegroundColor Yellow
Write-Host "Change Set: $ChangeSetName" -ForegroundColor Yellow
Write-Host "Execute Changes: $Execute" -ForegroundColor Yellow
Write-Host "Key Pair: $KeyPairName" -ForegroundColor Yellow
Write-Host "Domain: $DomainName" -ForegroundColor Yellow
Write-Host "Public Hosted Zone ID: Z01350882HWVKQIM61CH3 (hardcoded)" -ForegroundColor Yellow
Write-Host "VPN/NAT Private IP: $VPNNATPrivateIP" -ForegroundColor Yellow
if ($PrivateHostedZoneId) {
    Write-Host "Private Hosted Zone ID: $PrivateHostedZoneId" -ForegroundColor Yellow
} else {
    Write-Host "Private Hosted Zone: Will be created" -ForegroundColor Yellow
}

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

# Check if key pair exists
try {
    aws ec2 describe-key-pairs --key-names $KeyPairName --region $Region --profile $Profile --output table | Out-Null
    Write-Host "Key pair '$KeyPairName' found" -ForegroundColor Green
} catch {
    Write-Error "Key pair '$KeyPairName' not found in region $Region"
    Write-Host "Create a key pair first with: aws ec2 create-key-pair --key-name $KeyPairName --region $Region --profile $Profile" -ForegroundColor Yellow
    exit 1
}

# Check if stack exists
try {
    $stack = aws cloudformation describe-stacks --stack-name $NetworkStackName --region $Region --profile $Profile --output json | ConvertFrom-Json
    Write-Host "Stack '$NetworkStackName' found (Status: $($stack.Stacks[0].StackStatus))" -ForegroundColor Green
} catch {
    Write-Error "Stack '$NetworkStackName' not found in region $Region"
    exit 1
}

# Create Change Set
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "CREATING CHANGE SET" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Creating change set for devcloud network stack..." -ForegroundColor Blue
    
    # Build parameters JSON
    $parametersJson = @(
        @{ ParameterKey = "KeyPairName"; ParameterValue = $KeyPairName },
        @{ ParameterKey = "DomainName"; ParameterValue = $DomainName },
        @{ ParameterKey = "VpcCidr"; ParameterValue = $VpcCidr },
        @{ ParameterKey = "PublicSubnetCidr"; ParameterValue = $PublicSubnetCidr },
        @{ ParameterKey = "PrivateSubnetCidr"; ParameterValue = $PrivateSubnetCidr },
        @{ ParameterKey = "SecondPrivateSubnetCidr"; ParameterValue = $SecondPrivateSubnetCidr },
        @{ ParameterKey = "PrivateHostedZoneId"; ParameterValue = $PrivateHostedZoneId },
        @{ ParameterKey = "VPNNATPrivateIP"; ParameterValue = $VPNNATPrivateIP }
    ) | ConvertTo-Json -Compress
    
    $changeSetArgs = @(
        "cloudformation", "create-change-set",
        "--stack-name", $NetworkStackName,
        "--change-set-name", $ChangeSetName,
        "--template-body", "file://01-network-devcloud.yaml",
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_NAMED_IAM",
        "--parameters", $parametersJson
    )
    
    & aws @changeSetArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Change set '$ChangeSetName' created successfully!" -ForegroundColor Green
    } else {
        Write-Error "Failed to create change set"
        exit 1
    }
} catch {
    Write-Error "Error creating change set: $_"
    exit 1
}

# Wait for change set to be ready
Write-Host "Waiting for change set to be ready..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# Describe Change Set
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "DESCRIBING CHANGE SET" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Change set details:" -ForegroundColor Blue
    
    $describeArgs = @(
        "cloudformation", "describe-change-set",
        "--stack-name", $NetworkStackName,
        "--change-set-name", $ChangeSetName,
        "--region", $Region,
        "--profile", $Profile,
        "--output", "table"
    )
    
    & aws @describeArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to describe change set"
        exit 1
    }
} catch {
    Write-Error "Error describing change set: $_"
    exit 1
}

# Execute or Delete Change Set
Write-Host "`n" + "="*60 -ForegroundColor Blue
if ($Execute) {
    Write-Host "EXECUTING CHANGE SET" -ForegroundColor Blue
} else {
    Write-Host "DELETING CHANGE SET" -ForegroundColor Blue
}
Write-Host "="*60 -ForegroundColor Blue

if ($Execute) {
    try {
        Write-Host "Executing change set '$ChangeSetName'..." -ForegroundColor Blue
        
        $executeArgs = @(
            "cloudformation", "execute-change-set",
            "--stack-name", $NetworkStackName,
            "--change-set-name", $ChangeSetName,
            "--region", $Region,
            "--profile", $Profile
        )
        
        & aws @executeArgs

        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Change set executed successfully!" -ForegroundColor Green
            
            # Wait and show final stack status
            Write-Host "Waiting for stack update to complete..." -ForegroundColor Yellow
            Start-Sleep -Seconds 30
            
            Write-Host "`nFinal Stack Status:" -ForegroundColor Blue
            aws cloudformation describe-stacks --stack-name $NetworkStackName --region $Region --profile $Profile --query 'Stacks[0].StackStatus' --output text
            
            # Get network stack outputs
            Write-Host "`nNetwork Stack Outputs:" -ForegroundColor Blue
            aws cloudformation describe-stacks --stack-name $NetworkStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output table
            
        } else {
            Write-Error "Failed to execute change set"
            exit 1
        }
    } catch {
        Write-Error "Error executing change set: $_"
        exit 1
    }
} else {
    try {
        Write-Host "Deleting change set '$ChangeSetName'..." -ForegroundColor Blue
        
        $deleteArgs = @(
            "cloudformation", "delete-change-set",
            "--stack-name", $NetworkStackName,
            "--change-set-name", $ChangeSetName,
            "--region", $Region,
            "--profile", $Profile
        )
        
        & aws @deleteArgs

        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Change set deleted successfully!" -ForegroundColor Green
        } else {
            Write-Error "Failed to delete change set"
            exit 1
        }
    } catch {
        Write-Error "Error deleting change set: $_"
        exit 1
    }
}

Write-Host "`nNetwork Information:" -ForegroundColor Yellow
Write-Host "  VPC CIDR: $VpcCidr" -ForegroundColor White
Write-Host "  Public Subnet: $PublicSubnetCidr" -ForegroundColor White
Write-Host "  Private Subnet: $PrivateSubnetCidr" -ForegroundColor White
Write-Host "  Second Private Subnet: $SecondPrivateSubnetCidr" -ForegroundColor White
Write-Host "  VPN/NAT Gateway: $VPNNATPrivateIP" -ForegroundColor White
Write-Host "  WireGuard VPN: 10.0.0.0/24" -ForegroundColor White

Write-Host "`n" + "="*60 -ForegroundColor Green
if ($Execute) {
    Write-Host "CHANGE SET EXECUTED SUCCESSFULLY!" -ForegroundColor Green
} else {
    Write-Host "CHANGE SET REVIEWED AND DELETED!" -ForegroundColor Green
}
Write-Host "="*60 -ForegroundColor Green