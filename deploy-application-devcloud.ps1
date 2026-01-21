#!/usr/bin/env pwsh

# AWS DevCloud Application Deployment Script (DevCloud Version)
# Deploys: Application Instance, EFS, Data S3 Bucket
# Defaults to validation/dry-run mode. Use -Deploy to actually deploy.

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
    [string]$Profile = "bytecatdev",

    [Parameter(Mandatory=$false)]
    [switch]$Deploy
)

# Auto-generate application stack name if not provided
if ([string]::IsNullOrEmpty($ApplicationStackName)) {
    $ApplicationStackName = "devcloud-app-$ApplicationName"
}

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud Application Deployment (DevCloud Version)" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green
Write-Host "Mode: $(if ($Deploy) { 'DEPLOY' } else { 'VALIDATE/DRY-RUN' })" -ForegroundColor $(if ($Deploy) { 'Red' } else { 'Yellow' })
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

if (-not $Deploy) {
    Write-Host "Press Enter to continue with validation/dry-run or Ctrl+C to cancel..." -ForegroundColor Yellow
} else {
    Write-Host "Press Enter to continue with DEPLOYMENT or Ctrl+C to cancel..." -ForegroundColor Red
}
Read-Host

# Validate template
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "VALIDATING TEMPLATE: 02-application-devcloud.yaml" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    $validateArgs = @(
        "cloudformation", "validate-template",
        "--template-body", "file://02-application-devcloud.yaml",
        "--region", $Region,
        "--profile", $Profile
    )

    $validationResult = & aws @validateArgs
    Write-Host "✓ Template validation successful!" -ForegroundColor Green
} catch {
    Write-Error "Template validation failed: $_"
    exit 1
}

if (-not $Deploy) {
    # Dry-run mode: Create a change set to show what would be deployed
    Write-Host "`n" + "="*60 -ForegroundColor Yellow
    Write-Host "DRY-RUN: Creating Change Set for Application Stack" -ForegroundColor Yellow
    Write-Host "="*60 -ForegroundColor Yellow

    $changeSetName = "$ApplicationStackName-dryrun-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    try {
        $templateBody = Get-Content "02-application-devcloud.yaml" -Raw

        $changeSetArgs = @(
            "cloudformation", "create-change-set",
            "--change-set-name", $changeSetName,
            "--stack-name", $ApplicationStackName,
            "--template-body", $templateBody,
            "--region", $Region,
            "--profile", $Profile,
            "--capabilities", "CAPABILITY_NAMED_IAM",
            "--parameters",
            "ParameterKey=KeyPairName,ParameterValue=$KeyPairName",
            "ParameterKey=NetworkStackName,ParameterValue=$NetworkStackName",
            "ParameterKey=DomainName,ParameterValue=$DomainName",
            "ParameterKey=PrivateInstanceIP,ParameterValue=$PrivateInstanceIP",
            "ParameterKey=ApplicationName,ParameterValue=$ApplicationName"
        )

        & aws @changeSetArgs

        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Change set '$changeSetName' created successfully!" -ForegroundColor Green
            Write-Host "Review the change set in AWS Console or with:" -ForegroundColor Cyan
            Write-Host "aws cloudformation describe-change-set --change-set-name $changeSetName --stack-name $ApplicationStackName --region $Region --profile $Profile" -ForegroundColor Cyan
            Write-Host "`nTo actually deploy, run this script with -Deploy parameter." -ForegroundColor Yellow
        } else {
            Write-Error "Failed to create change set"
            exit 1
        }

    } catch {
        Write-Error "Failed to create change set: $_"
        exit 1
    }

} else {
    # Deploy mode
    Write-Host "`n" + "="*60 -ForegroundColor Red
    Write-Host "DEPLOYING APPLICATION: $ApplicationName" -ForegroundColor Red
    Write-Host "="*60 -ForegroundColor Red

    try {
        Write-Host "Deploying application stack..." -ForegroundColor Red

        $applicationArgs = @(
            "cloudformation", "deploy",
            "--template-file", "02-application-devcloud.yaml",
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
            try {
                $appStack = aws cloudformation describe-stacks --stack-name $ApplicationStackName --region $Region --profile $Profile --output json | ConvertFrom-Json
                $appOutputs = $appStack.Stacks[0].Outputs

                Write-Host "`nApplication Stack Outputs:" -ForegroundColor Green
                foreach ($output in $appOutputs) {
                    Write-Host "$($output.OutputKey): $($output.OutputValue)" -ForegroundColor Cyan
                }
            } catch {
                Write-Warning "Could not retrieve application stack outputs"
            }

            Write-Host "`nNext steps:" -ForegroundColor Yellow
            Write-Host "1. Check instance status: .\manage-instances.ps1 -Action status -Instance private -NetworkStackName $NetworkStackName -ApplicationStackName $ApplicationStackName" -ForegroundColor Cyan
            Write-Host "2. SSH to instance: ssh -i ~/.ssh/$KeyPairName.pem ec2-user@$($appOutputs | Where-Object { $_.OutputKey -eq 'PrivateInstancePrivateIP' }).OutputValue" -ForegroundColor Cyan
            Write-Host "3. View logs: aws ec2 get-console-output --instance-id $($appOutputs | Where-Object { $_.OutputKey -eq 'PrivateInstanceId' }).OutputValue --region $Region --profile $Profile" -ForegroundColor Cyan

        } else {
            Write-Error "Application stack deployment failed!"
            exit 1
        }

    } catch {
        Write-Error "Application deployment failed: $_"
        exit 1
    }
}

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "SCRIPT COMPLETED" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green