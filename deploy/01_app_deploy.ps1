#!/usr/bin/env pwsh

# AWS Bytecatd Application Deployment Script
# Defaults to a stable stack name so reruns update the same resources.
# Pass a different -ApplicationStackName when you intentionally want a parallel deployment.
# Defaults to validation/dry-run mode. Use -Deploy to actually deploy.

param(
    [Parameter(Mandatory=$true)]
    [string]$KeyPairName,

    [Parameter(Mandatory=$true)]
    [string]$VpcId,

    [Parameter(Mandatory=$true)]
    [string]$PrivateSubnetId,

    [Parameter(Mandatory=$false)]
    [string]$ApplicationStackName = "bytecatd-app",

    [Parameter(Mandatory=$false)]
    [string]$ApplicationName = "",

    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",

    [Parameter(Mandatory=$false)]
    [string]$PrivateInstanceType = "t3.large",

    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev",

    [Parameter(Mandatory=$false)]
    [switch]$Deploy
)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $ScriptRoot
$ManifestPath = Join-Path $ScriptRoot ".last_parallel_deployment.json"
$TemplateFile = "deploy/01_app_deploy.yaml"

function Save-DeploymentManifest {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$DeploymentData
    )

    $DeploymentData | ConvertTo-Json | Set-Content -Path $ManifestPath -Encoding UTF8
}

function Test-CloudFormationStackExists {
    param(
        [Parameter(Mandatory=$true)]
        [string]$StackName
    )

    $null = aws cloudformation describe-stacks --stack-name $StackName --region $Region --profile $Profile --output json 2>$null
    return ($LASTEXITCODE -eq 0)
}

if ([string]::IsNullOrWhiteSpace($ApplicationName)) {
    $ApplicationName = $ApplicationStackName
}

$env:AWS_PROFILE = $Profile

Push-Location $RepositoryRoot
try {
    Write-Host "AWS Bytecatd Application Deployment" -ForegroundColor Green
    Write-Host "==================================" -ForegroundColor Green
    Write-Host "Mode: $(if ($Deploy) { 'DEPLOY' } else { 'VALIDATE/DRY-RUN' })" -ForegroundColor $(if ($Deploy) { 'Red' } else { 'Yellow' })
    Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
    Write-Host "Region: $Region" -ForegroundColor Yellow
    Write-Host "Application Stack: $ApplicationStackName" -ForegroundColor Yellow
    Write-Host "Application Name: $ApplicationName" -ForegroundColor Yellow
    if ($ApplicationStackName -eq "bytecatd-app") {
        Write-Host "Deployment target: default stack (reruns update the same resources)" -ForegroundColor Yellow
    } else {
        Write-Host "Deployment target: custom stack name for a parallel deployment" -ForegroundColor Yellow
    }
    Write-Host "Key Pair: $KeyPairName" -ForegroundColor Yellow
    Write-Host "VPC ID: $VpcId" -ForegroundColor Yellow
    Write-Host "Private Instance Type: $PrivateInstanceType" -ForegroundColor Yellow
    Write-Host "Private Subnet ID: $PrivateSubnetId" -ForegroundColor Yellow

    try {
        $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
        Write-Host "Deploying to AWS Account: $($identity.Account)" -ForegroundColor Green
    } catch {
        Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
        exit 1
    }

    try {
        aws ec2 describe-key-pairs --key-names $KeyPairName --region $Region --profile $Profile --output table | Out-Null
        Write-Host "Key pair '$KeyPairName' found" -ForegroundColor Green
    } catch {
        Write-Error "Key pair '$KeyPairName' not found in region $Region"
        exit 1
    }

    try {
        aws ec2 describe-vpcs --vpc-ids $VpcId --region $Region --profile $Profile --output table | Out-Null
        Write-Host "VPC '$VpcId' found" -ForegroundColor Green
    } catch {
        Write-Error "VPC '$VpcId' not found in region $Region"
        exit 1
    }

    $manifest = @{
        ApplicationStackName = $ApplicationStackName
        ApplicationName = $ApplicationName
        PrivateInstanceType = $PrivateInstanceType
        PrivateSubnetId = $PrivateSubnetId
        VpcId = $VpcId
        Region = $Region
        Profile = $Profile
        UpdatedAt = (Get-Date).ToString("o")
    }
    Save-DeploymentManifest -DeploymentData $manifest
    Write-Host "Deployment manifest saved to: $ManifestPath" -ForegroundColor DarkGray

    if (-not $Deploy) {
        Write-Host "Press Enter to continue with validation/dry-run or Ctrl+C to cancel..." -ForegroundColor Yellow
    } else {
        Write-Host "Press Enter to continue with DEPLOYMENT or Ctrl+C to cancel..." -ForegroundColor Red
    }
    Read-Host

    Write-Host "`n" + "="*60 -ForegroundColor Blue
    Write-Host "VALIDATING TEMPLATE: $TemplateFile" -ForegroundColor Blue
    Write-Host "="*60 -ForegroundColor Blue

    try {
        $validateArgs = @(
            "cloudformation", "validate-template",
            "--template-body", "file://$TemplateFile",
            "--region", $Region,
            "--profile", $Profile
        )

        & aws @validateArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Template validation failed"
            exit 1
        }
        Write-Host "✓ Template validation successful!" -ForegroundColor Green
    } catch {
        Write-Error "Template validation failed: $_"
        exit 1
    }

    if (-not $Deploy) {
        Write-Host "`n" + "="*60 -ForegroundColor Yellow
        Write-Host "DRY-RUN: Creating Change Set for Application Stack" -ForegroundColor Yellow
        Write-Host "="*60 -ForegroundColor Yellow

        $changeSetName = "$ApplicationStackName-dryrun-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $changeSetType = if (Test-CloudFormationStackExists -StackName $ApplicationStackName) { 'UPDATE' } else { 'CREATE' }
        Write-Host "Change set type: $changeSetType" -ForegroundColor Yellow

        try {
            $changeSetArgs = @(
                "cloudformation", "create-change-set",
                "--change-set-name", $changeSetName,
                "--change-set-type", $changeSetType,
                "--stack-name", $ApplicationStackName,
                "--template-body", "file://$TemplateFile",
                "--region", $Region,
                "--profile", $Profile,
                "--capabilities", "CAPABILITY_NAMED_IAM",
                "--parameters",
                "ParameterKey=KeyPairName,ParameterValue=$KeyPairName",
                "ParameterKey=VpcId,ParameterValue=$VpcId",
                "ParameterKey=PrivateSubnetId,ParameterValue=$PrivateSubnetId",
                "ParameterKey=PrivateInstanceType,ParameterValue=$PrivateInstanceType",
                "ParameterKey=ApplicationName,ParameterValue=$ApplicationName"
            )

            & aws @changeSetArgs | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Change set '$changeSetName' created successfully!" -ForegroundColor Green
                Write-Host "This deployment will use:" -ForegroundColor Cyan
                Write-Host "  - Change Set Type: $changeSetType" -ForegroundColor White
                Write-Host "  - Application Stack: $ApplicationStackName" -ForegroundColor White
                Write-Host "  - Application Name: $ApplicationName" -ForegroundColor White
                Write-Host "  - Instance Type: $PrivateInstanceType" -ForegroundColor White
                Write-Host "  - Private IP: template default from $TemplateFile" -ForegroundColor White
                Write-Host "`nRun deploy\02_compute_deploy.ps1 next; it will pick up the application stack from the manifest." -ForegroundColor Yellow
            } else {
                Write-Error "Failed to create change set"
                exit 1
            }
        } catch {
            Write-Error "Failed to create change set: $_"
            exit 1
        }
    } else {
        Write-Host "`n" + "="*60 -ForegroundColor Red
        Write-Host "DEPLOYING APPLICATION: $ApplicationName" -ForegroundColor Red
        Write-Host "="*60 -ForegroundColor Red

        try {
            $applicationArgs = @(
                "cloudformation", "deploy",
                "--template-file", $TemplateFile,
                "--stack-name", $ApplicationStackName,
                "--region", $Region,
                "--profile", $Profile,
                "--capabilities", "CAPABILITY_NAMED_IAM",
                "--parameter-overrides",
                "KeyPairName=$KeyPairName",
                "VpcId=$VpcId",
                "PrivateSubnetId=$PrivateSubnetId",
                "PrivateInstanceType=$PrivateInstanceType",
                "ApplicationName=$ApplicationName",
                "--no-fail-on-empty-changeset",
                "--output", "table"
            )

            & aws @applicationArgs

            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Application stack deployed successfully!" -ForegroundColor Green

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

                Write-Host "`nDeployment details:" -ForegroundColor Yellow
                Write-Host "1. Application Stack: $ApplicationStackName" -ForegroundColor Cyan
                Write-Host "2. Application Name: $ApplicationName" -ForegroundColor Cyan
                Write-Host "3. Instance Type: $PrivateInstanceType" -ForegroundColor Cyan
                Write-Host "4. Private IP: template default from $TemplateFile" -ForegroundColor Cyan
                Write-Host "5. Run deploy\02_compute_deploy.ps1 to create matching compute resources for this app stack." -ForegroundColor Cyan
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
} finally {
    Pop-Location
}
