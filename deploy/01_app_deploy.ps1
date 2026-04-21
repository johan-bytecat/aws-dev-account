#!/usr/bin/env pwsh

# AWS Bytecatd Parallel Application Deployment Script
# Deploys a parallel-safe application stack with unique names and an auto-selected private IP.
# Defaults to validation/dry-run mode. Use -Deploy to actually deploy.

param(
    [Parameter(Mandatory=$true)]
    [string]$KeyPairName,

    [Parameter(Mandatory=$true)]
    [string]$PrivateSubnetId,

    [Parameter(Mandatory=$true)]
    [string]$PrivateSecurityGroupId,

    [Parameter(Mandatory=$true)]
    [string]$EFSSecurityGroupId,

    [Parameter(Mandatory=$false)]
    [string]$VpcId = "",

    [Parameter(Mandatory=$false)]
    [string]$ApplicationStackName = "",

    [Parameter(Mandatory=$false)]
    [string]$ApplicationName = "",

    [Parameter(Mandatory=$false)]
    [string]$DeploymentId = "",

    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",

    [Parameter(Mandatory=$false)]
    [string]$PrivateInstanceType = "t3.large",

    [Parameter(Mandatory=$false)]
    [string]$PrivateInstanceIP = "",

    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev",

    [Parameter(Mandatory=$false)]
    [switch]$Deploy
)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $ScriptRoot
$ManifestPath = Join-Path $ScriptRoot ".last_parallel_deployment.json"
$TemplateFile = "deploy/01_app_deploy.yaml"

function Get-NextAvailablePrivateIp {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SubnetId,

        [int]$StartHost = 101,
        [int]$EndHost = 250
    )

    $usedIpOutput = aws ec2 describe-instances --region $Region --profile $Profile --filters Name=subnet-id,Values=$SubnetId Name=instance-state-name,Values=pending,running,stopping,stopped --query "Reservations[].Instances[].PrivateIpAddress" --output text
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect existing private IP addresses in subnet '$SubnetId'."
    }

    $usedIps = @{}
    foreach ($ip in ($usedIpOutput -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $usedIps[$ip.Trim()] = $true
    }

    for ($host = $StartHost; $host -le $EndHost; $host++) {
        $candidate = "172.16.2.$host"
        if (-not $usedIps.ContainsKey($candidate)) {
            return $candidate
        }
    }

    throw "No free private IPs were found in the 172.16.2.$StartHost-$EndHost range."
}

function Save-DeploymentManifest {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$DeploymentData
    )

    $DeploymentData | ConvertTo-Json | Set-Content -Path $ManifestPath -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($DeploymentId)) {
    $DeploymentId = Get-Date -Format "yyyyMMddHHmmss"
}

if ([string]::IsNullOrWhiteSpace($ApplicationName)) {
    $ApplicationName = "kite-server-$DeploymentId"
}

if ([string]::IsNullOrWhiteSpace($ApplicationStackName)) {
    $ApplicationStackName = "bytecatd-app-$DeploymentId"
}

$env:AWS_PROFILE = $Profile

Push-Location $RepositoryRoot
try {
    Write-Host "AWS Bytecatd Parallel Application Deployment" -ForegroundColor Green
    Write-Host "===========================================" -ForegroundColor Green
    Write-Host "Mode: $(if ($Deploy) { 'DEPLOY' } else { 'VALIDATE/DRY-RUN' })" -ForegroundColor $(if ($Deploy) { 'Red' } else { 'Yellow' })
    Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
    Write-Host "Region: $Region" -ForegroundColor Yellow
    Write-Host "Deployment ID: $DeploymentId" -ForegroundColor Yellow
    Write-Host "Application Stack: $ApplicationStackName" -ForegroundColor Yellow
    Write-Host "Application Name: $ApplicationName" -ForegroundColor Yellow
    Write-Host "Key Pair: $KeyPairName" -ForegroundColor Yellow
    Write-Host "Private Instance Type: $PrivateInstanceType" -ForegroundColor Yellow
    Write-Host "Private Subnet ID: $PrivateSubnetId" -ForegroundColor Yellow
    Write-Host "Private Security Group ID: $PrivateSecurityGroupId" -ForegroundColor Yellow
    Write-Host "EFS Security Group ID: $EFSSecurityGroupId" -ForegroundColor Yellow

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
        if ([string]::IsNullOrWhiteSpace($PrivateInstanceIP)) {
            $PrivateInstanceIP = Get-NextAvailablePrivateIp -SubnetId $PrivateSubnetId
            Write-Host "Auto-selected free private IP: $PrivateInstanceIP" -ForegroundColor Green
        } else {
            Write-Host "Using provided private IP: $PrivateInstanceIP" -ForegroundColor Yellow
        }
    } catch {
        Write-Error $_
        exit 1
    }

    $manifest = @{
        DeploymentId = $DeploymentId
        ApplicationStackName = $ApplicationStackName
        ApplicationName = $ApplicationName
        PrivateInstanceType = $PrivateInstanceType
        PrivateInstanceIP = $PrivateInstanceIP
        PrivateSubnetId = $PrivateSubnetId
        PrivateSecurityGroupId = $PrivateSecurityGroupId
        EFSSecurityGroupId = $EFSSecurityGroupId
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

        try {
            $changeSetArgs = @(
                "cloudformation", "create-change-set",
                "--change-set-name", $changeSetName,
                "--stack-name", $ApplicationStackName,
                "--template-body", "file://$TemplateFile",
                "--region", $Region,
                "--profile", $Profile,
                "--capabilities", "CAPABILITY_NAMED_IAM",
                "--parameters",
                "ParameterKey=KeyPairName,ParameterValue=$KeyPairName",
                "ParameterKey=PrivateSubnetId,ParameterValue=$PrivateSubnetId",
                "ParameterKey=PrivateSecurityGroupId,ParameterValue=$PrivateSecurityGroupId",
                "ParameterKey=EFSSecurityGroupId,ParameterValue=$EFSSecurityGroupId",
                "ParameterKey=PrivateInstanceType,ParameterValue=$PrivateInstanceType",
                "ParameterKey=PrivateInstanceIP,ParameterValue=$PrivateInstanceIP",
                "ParameterKey=ApplicationName,ParameterValue=$ApplicationName"
            )

            & aws @changeSetArgs | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Change set '$changeSetName' created successfully!" -ForegroundColor Green
                Write-Host "This parallel deployment will use:" -ForegroundColor Cyan
                Write-Host "  - Deployment ID: $DeploymentId" -ForegroundColor White
                Write-Host "  - Application Stack: $ApplicationStackName" -ForegroundColor White
                Write-Host "  - Application Name: $ApplicationName" -ForegroundColor White
                Write-Host "  - Instance Type: $PrivateInstanceType" -ForegroundColor White
                Write-Host "  - Private IP: $PrivateInstanceIP" -ForegroundColor White
                Write-Host "`nUse the same Deployment ID when running deploy\02_compute_deploy.ps1." -ForegroundColor Yellow
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
                "PrivateSubnetId=$PrivateSubnetId",
                "PrivateSecurityGroupId=$PrivateSecurityGroupId",
                "EFSSecurityGroupId=$EFSSecurityGroupId",
                "PrivateInstanceType=$PrivateInstanceType",
                "PrivateInstanceIP=$PrivateInstanceIP",
                "ApplicationName=$ApplicationName",
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

                Write-Host "`nParallel deployment details:" -ForegroundColor Yellow
                Write-Host "1. Deployment ID: $DeploymentId" -ForegroundColor Cyan
                Write-Host "2. Application Stack: $ApplicationStackName" -ForegroundColor Cyan
                Write-Host "3. Instance Type: $PrivateInstanceType" -ForegroundColor Cyan
                Write-Host "4. Private IP: $PrivateInstanceIP" -ForegroundColor Cyan
                Write-Host "5. Run deploy\02_compute_deploy.ps1 with -DeploymentId $DeploymentId to create matching compute resources." -ForegroundColor Cyan
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
