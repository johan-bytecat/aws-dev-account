#!/usr/bin/env pwsh

# AWS DevCloud Network Infrastructure Deployment Script
# Deploys: VPC, NAT Gateway, Security Groups, S3 Scripts Bucket

param(
    [Parameter(Mandatory=$true)]
    [string]$KeyPairName,
    
    [Parameter(Mandatory=$false)]
    [string]$NetworkStackName = "bytecat-network",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$DomainName = "bytecat.co.za",
    
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
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud Network Infrastructure Deployment" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Network Stack: $NetworkStackName" -ForegroundColor Yellow
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
    Write-Host "Deploying to AWS Account: $($identity.Account)" -ForegroundColor Green
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

# Deploy Network Infrastructure
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "DEPLOYING NETWORK INFRASTRUCTURE" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Deploying network stack (VPC, NAT, Security Groups)..." -ForegroundColor Blue
    
    $networkArgs = @(
        "cloudformation", "deploy",
        "--template-file", "01-network.yaml",
        "--stack-name", $NetworkStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_NAMED_IAM",
        "--parameter-overrides", 
        "KeyPairName=$KeyPairName",
        "DomainName=$DomainName",
        "VpcCidr=$VpcCidr",
        "PublicSubnetCidr=$PublicSubnetCidr",
        "PrivateSubnetCidr=$PrivateSubnetCidr",
        "SecondPrivateSubnetCidr=$SecondPrivateSubnetCidr",
        "PrivateHostedZoneId=$PrivateHostedZoneId",
        "VPNNATPrivateIP=$VPNNATPrivateIP",
        "--output", "table"
    )
    
    & aws @networkArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Network stack deployed successfully!" -ForegroundColor Green
        
        # Get network stack outputs
        Write-Host "`nNetwork Stack Outputs:" -ForegroundColor Blue
        aws cloudformation describe-stacks --stack-name $NetworkStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output table
        
    } else {
        Write-Error "Network stack deployment failed"
        exit 1
    }
} catch {
    Write-Error "Error deploying network stack: $_"
    exit 1
}

# Upload Scripts Instructions
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "NEXT: UPLOAD SCRIPTS TO S3" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

Write-Host "`nNetwork deployment completed successfully!" -ForegroundColor Green
Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Upload scripts to S3 bucket:" -ForegroundColor White
Write-Host "   .\upload-scripts.ps1 -NetworkStackName $NetworkStackName" -ForegroundColor Cyan
Write-Host "`n2. Deploy application(s) on the network:" -ForegroundColor White
Write-Host "   .\deploy-application.ps1 -KeyPairName $KeyPairName -NetworkStackName $NetworkStackName -ApplicationName kite-server" -ForegroundColor Cyan
Write-Host "`n3. Manage instances:" -ForegroundColor White
Write-Host "   .\manage-instances.ps1 -Action status -NetworkStackName $NetworkStackName" -ForegroundColor Cyan

Write-Host "Network Information:" -ForegroundColor Yellow
Write-Host "  VPC CIDR: $VpcCidr" -ForegroundColor White
Write-Host "  Public Subnet: $PublicSubnetCidr" -ForegroundColor White
Write-Host "  Private Subnet: $PrivateSubnetCidr" -ForegroundColor White
Write-Host "  Second Private Subnet: $SecondPrivateSubnetCidr" -ForegroundColor White
Write-Host "  VPN/NAT Gateway: $VPNNATPrivateIP" -ForegroundColor White
Write-Host "  WireGuard VPN: 10.0.0.0/24" -ForegroundColor White

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "NETWORK DEPLOYMENT COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green
