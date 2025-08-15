#!/usr/bin/env pwsh

# AWS DevCloud Application Deployment Script
# Deploys: Application Instance, EFS, Data S3 Bucket

param(
    [Parameter(Mandatory=$true)]
    [string]$KeyPairName,
    
    [Parameter(Mandatory=$false)]
    [string]$NetworkStackName = "devcloud-network",
    
    [Parameter(Mandatory=$false)]
    [string]$ApplicationStackName = "",  # Will be auto-generated if not provided
    
    [Parameter(Mandatory=$false)]
    [string]$ApplicationName = "kite-server",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$DomainName = "devcloud.bytecat.co.za",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateInstanceIP = "172.16.2.100",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Auto-generate application stack name if not provided
if ([string]::IsNullOrEmpty($ApplicationStackName)) {
    $ApplicationStackName = "devcloud-app-$ApplicationName"
}

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud Application Deployment" -ForegroundColor Green
Write-Host "===================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Network Stack: $NetworkStackName" -ForegroundColor Yellow
Write-Host "Application Stack: $ApplicationStackName" -ForegroundColor Yellow
Write-Host "Application Name: $ApplicationName" -ForegroundColor Yellow
Write-Host "Key Pair: $KeyPairName" -ForegroundColor Yellow
Write-Host "Domain: $DomainName" -ForegroundColor Yellow
Write-Host "Private Instance IP: $PrivateInstanceIP" -ForegroundColor Yellow

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

# Check if network stack exists
try {
    $networkStack = aws cloudformation describe-stacks --stack-name $NetworkStackName --region $Region --profile $Profile --output json | ConvertFrom-Json
    Write-Host "✓ Network stack '$NetworkStackName' found" -ForegroundColor Green
    
    # Check if network stack is in a good state
    $stackStatus = $networkStack.Stacks[0].StackStatus
    if ($stackStatus -eq "CREATE_COMPLETE" -or $stackStatus -eq "UPDATE_COMPLETE") {
        Write-Host "Network stack status: $stackStatus ✓" -ForegroundColor Green
    } else {
        Write-Error "Network stack is in state: $stackStatus (not ready for application deployment)"
        exit 1
    }
} catch {
    Write-Error "Network stack '$NetworkStackName' not found in region $Region"
    Write-Host "Deploy network infrastructure first with: .\deploy-network.ps1 -KeyPairName $KeyPairName" -ForegroundColor Yellow
    exit 1
}

# Get network stack information for verification
try {
    Write-Host "`nVerifying network infrastructure..." -ForegroundColor Yellow
    $networkOutputs = $networkStack.Stacks[0].Outputs
    $vpnNatInstanceId = ($networkOutputs | Where-Object { $_.OutputKey -eq "VPNNATInstanceId" }).OutputValue
    $vpnNatPublicIP = ($networkOutputs | Where-Object { $_.OutputKey -eq "VPNNATPublicIP" }).OutputValue
    $vpnNatPrivateIP = ($networkOutputs | Where-Object { $_.OutputKey -eq "VPNNATPrivateIP" }).OutputValue
    $scriptsBucket = ($networkOutputs | Where-Object { $_.OutputKey -eq "ScriptsBucketName" }).OutputValue
    
    Write-Host "VPN/NAT Instance ID: $vpnNatInstanceId" -ForegroundColor Cyan
    Write-Host "VPN/NAT Public IP: $vpnNatPublicIP" -ForegroundColor Cyan
    Write-Host "VPN/NAT Private IP: $vpnNatPrivateIP" -ForegroundColor Cyan
    Write-Host "Scripts Bucket: $scriptsBucket" -ForegroundColor Cyan
    
    # Check NAT instance state
    $instanceState = aws ec2 describe-instances --instance-ids $vpnNatInstanceId --region $Region --profile $Profile --query 'Reservations[0].Instances[0].State.Name' --output text
    Write-Host "VPN/NAT Instance State: $instanceState" -ForegroundColor Cyan
    
    if ($instanceState -ne "running") {
        Write-Warning "VPN/NAT instance is not running. The application instance may not have internet connectivity."
        Write-Host "You can start it with: .\manage-instances.ps1 -Action start -Instance vpn-nat -NetworkStackName $NetworkStackName" -ForegroundColor Yellow
    }
} catch {
    Write-Warning "Could not verify network infrastructure details"
}

# Verify scripts are uploaded
Write-Host "`nVerifying scripts are uploaded to S3..." -ForegroundColor Yellow
Write-Host "Make sure you have run: .\upload-scripts.ps1 -NetworkStackName $NetworkStackName" -ForegroundColor Cyan
Write-Host "Press Enter to continue or Ctrl+C to cancel..." -ForegroundColor Yellow
Read-Host

# Deploy Application
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "DEPLOYING APPLICATION: $ApplicationName" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Deploying application stack..." -ForegroundColor Blue
    
    $applicationArgs = @(
        "cloudformation", "deploy",
        "--template-file", "02-application.yaml",
        "--stack-name", $ApplicationStackName,
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_NAMED_IAM",
        "--parameter-overrides", 
        "KeyPairName=$KeyPairName",
        "NetworkStackName=$NetworkStackName",
        "DomainName=$DomainName",
        "PrivateInstanceIP=$PrivateInstanceIP",
        "ApplicationName=$ApplicationName",
        "--output", "table"
    )
    
    & aws @applicationArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Application stack deployed successfully!" -ForegroundColor Green
        
        # Get application stack outputs
        Write-Host "`nApplication Stack Outputs:" -ForegroundColor Blue
        aws cloudformation describe-stacks --stack-name $ApplicationStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output table
        
    } else {
        Write-Error "Application stack deployment failed"
        exit 1
    }
} catch {
    Write-Error "Error deploying application stack: $_"
    exit 1
}

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "APPLICATION DEPLOYMENT COMPLETED!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green

Write-Host "`nDeployed Application: $ApplicationName" -ForegroundColor Yellow
Write-Host "Application Stack: $ApplicationStackName" -ForegroundColor Yellow

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Wait for application instance to fully initialize (check CloudWatch logs)" -ForegroundColor White
Write-Host "2. Configure WireGuard VPN clients to access the application" -ForegroundColor White
Write-Host "3. Access application through VPN at: $PrivateInstanceIP" -ForegroundColor White

Write-Host "`nInstance Management:" -ForegroundColor Yellow
Write-Host "  Status: .\manage-instances.ps1 -Action status -NetworkStackName $NetworkStackName -ApplicationStackName $ApplicationStackName" -ForegroundColor White
Write-Host "  Start:  .\manage-instances.ps1 -Action start -Instance app -ApplicationStackName $ApplicationStackName" -ForegroundColor White
Write-Host "  Stop:   .\manage-instances.ps1 -Action stop -Instance app -ApplicationStackName $ApplicationStackName" -ForegroundColor White

Write-Host "`nApplication Resources:" -ForegroundColor Yellow
Write-Host "  Instance IP: $PrivateInstanceIP" -ForegroundColor White
Write-Host "  Data Bucket: devcloud-data-$ApplicationName-$($identity.Account)" -ForegroundColor White
Write-Host "  EFS Mount: /mnt/efs (on instance)" -ForegroundColor White

Write-Host "`nConnectivity Testing:" -ForegroundColor Yellow
Write-Host "  From VPN: ssh -i $KeyPairName.pem ec2-user@$PrivateInstanceIP" -ForegroundColor Cyan

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "APPLICATION '$ApplicationName' READY!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green
