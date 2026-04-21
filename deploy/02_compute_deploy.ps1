#!/usr/bin/env pwsh

# AWS Bytecatd Parallel Compute Deployment Script
# Deploys a parallel-safe compute stack that targets the matching parallel application stack.
# Defaults to validation mode. Use -Deploy to actually deploy.

param(
    [Parameter(Mandatory=$false)]
    [string]$ApplicationStackName = "",

    [Parameter(Mandatory=$false)]
    [string]$DeploymentId = "",

    [Parameter(Mandatory=$false)]
    [string]$ComputeStackName = "",

    [Parameter(Mandatory=$false)]
    [string]$VpcId = "",

    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",

    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev",

    [Parameter(Mandatory=$false)]
    [switch]$Deploy
)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $ScriptRoot
$ManifestPath = Join-Path $ScriptRoot ".last_parallel_deployment.json"
$TemplateFile = "deploy/02_compute_deploy.yaml"

function Get-LastParallelDeployment {
    if (-not (Test-Path $ManifestPath)) {
        return $null
    }

    try {
        return Get-Content $ManifestPath -Raw | ConvertFrom-Json
    } catch {
        throw "Could not read deployment manifest at '$ManifestPath'."
    }
}

function Save-DeploymentManifest {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$DeploymentData
    )

    $DeploymentData | ConvertTo-Json | Set-Content -Path $ManifestPath -Encoding UTF8
}

function Remove-BadStackState {
    param(
        [string]$StackName,
        [string]$StackStatus
    )

    $badStates = @("REVIEW_IN_PROGRESS", "CREATE_FAILED", "ROLLBACK_COMPLETE", "ROLLBACK_FAILED", "DELETE_FAILED")

    if ($StackStatus -in $badStates) {
        Write-Warning "Stack '$StackName' is in state: $StackStatus"
        Write-Host "Cleaning up stack before proceeding..." -ForegroundColor Yellow

        aws cloudformation delete-stack --stack-name $StackName --region $Region --profile $Profile 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Waiting for stack deletion to complete..." -ForegroundColor Yellow
            aws cloudformation wait stack-delete-complete --stack-name $StackName --region $Region --profile $Profile 2>$null
            Write-Host "✓ Stack cleanup completed" -ForegroundColor Green
            return $true
        }

        Write-Error "Failed to delete stack in bad state. Manual intervention may be required."
        return $false
    }

    return $true
}

$manifest = Get-LastParallelDeployment
if (-not [string]::IsNullOrWhiteSpace($DeploymentId)) {
    if ([string]::IsNullOrWhiteSpace($ApplicationStackName)) {
        $ApplicationStackName = "bytecatd-app-$DeploymentId"
    }

    if ([string]::IsNullOrWhiteSpace($ComputeStackName)) {
        $ComputeStackName = "bytecatd-compute-$DeploymentId"
    }
} elseif ($manifest) {
    if ([string]::IsNullOrWhiteSpace($ApplicationStackName)) {
        $ApplicationStackName = [string]$manifest.ApplicationStackName
    }

    if ([string]::IsNullOrWhiteSpace($ComputeStackName) -and -not [string]::IsNullOrWhiteSpace([string]$manifest.DeploymentId)) {
        $ComputeStackName = "bytecatd-compute-$($manifest.DeploymentId)"
    }

    if ([string]::IsNullOrWhiteSpace($DeploymentId)) {
        $DeploymentId = [string]$manifest.DeploymentId
    }

    if ([string]::IsNullOrWhiteSpace($VpcId) -and $manifest.PSObject.Properties.Name -contains 'VpcId') {
        $VpcId = [string]$manifest.VpcId
    }

}

if ([string]::IsNullOrWhiteSpace($ApplicationStackName)) {
    Write-Error "ApplicationStackName is required. Run deploy\01_app_deploy.ps1 first or supply -DeploymentId / -ApplicationStackName explicitly."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ComputeStackName)) {
    if ($ApplicationStackName -like "bytecatd-app-*") {
        $ComputeStackName = $ApplicationStackName -replace "^bytecatd-app-", "bytecatd-compute-"
    } else {
        $ComputeStackName = "$ApplicationStackName-compute"
    }
}

if ([string]::IsNullOrWhiteSpace($VpcId)) {
    Write-Error "VpcId is required. Supply it directly or include it when running deploy\01_app_deploy.ps1 so it is stored in the manifest."
    exit 1
}

$env:AWS_PROFILE = $Profile

Push-Location $RepositoryRoot
try {
    Write-Host "AWS Bytecatd Parallel Compute Deployment" -ForegroundColor Green
    Write-Host "=======================================" -ForegroundColor Green
    Write-Host "Mode: $(if ($Deploy) { 'DEPLOY' } else { 'VALIDATE ONLY' })" -ForegroundColor $(if ($Deploy) { 'Red' } else { 'Yellow' })
    Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
    Write-Host "Region: $Region" -ForegroundColor Yellow
    Write-Host "Deployment ID: $(if ([string]::IsNullOrWhiteSpace($DeploymentId)) { 'manual' } else { $DeploymentId })" -ForegroundColor Yellow
    Write-Host "Application Stack: $ApplicationStackName" -ForegroundColor Yellow
    Write-Host "Compute Stack: $ComputeStackName" -ForegroundColor Yellow
    Write-Host "VPC ID: $VpcId" -ForegroundColor Yellow

    try {
        $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
        Write-Host "Deploying to AWS Account: $($identity.Account)" -ForegroundColor Green
    } catch {
        Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
        exit 1
    }

    try {
        $appStack = aws cloudformation describe-stacks --stack-name $ApplicationStackName --region $Region --profile $Profile --output json | ConvertFrom-Json
        Write-Host "✓ Application stack '$ApplicationStackName' found" -ForegroundColor Green

        $stackStatus = $appStack.Stacks[0].StackStatus
        if ($stackStatus -eq "CREATE_COMPLETE" -or $stackStatus -eq "UPDATE_COMPLETE") {
            Write-Host "Application stack status: $stackStatus ✓" -ForegroundColor Green
        } else {
            Write-Error "Application stack is in state: $stackStatus (not ready for compute deployment)"
            exit 1
        }
    } catch {
        Write-Error "Application stack '$ApplicationStackName' not found in region $Region"
        Write-Host "Run deploy\01_app_deploy.ps1 first, or pass the matching parallel application stack name." -ForegroundColor Yellow
        exit 1
    }

    $stackExists = $false
    try {
        $existingStack = aws cloudformation describe-stacks --stack-name $ComputeStackName --region $Region --profile $Profile --output json 2>$null | ConvertFrom-Json
        if ($existingStack -and $existingStack.Stacks.Count -gt 0) {
            $computeStackStatus = $existingStack.Stacks[0].StackStatus
            Write-Host "Existing compute stack found with status: $computeStackStatus" -ForegroundColor Yellow

            if (-not (Remove-BadStackState -StackName $ComputeStackName -StackStatus $computeStackStatus)) {
                exit 1
            }

            try {
                $recheckStack = aws cloudformation describe-stacks --stack-name $ComputeStackName --region $Region --profile $Profile --output json 2>$null | ConvertFrom-Json
                if ($recheckStack -and $recheckStack.Stacks.Count -gt 0) {
                    $stackExists = $true
                }
            } catch {
                $stackExists = $false
            }
        }
    } catch {
        $stackExists = $false
    }

    $updatedManifest = @{
        DeploymentId = $DeploymentId
        ApplicationStackName = $ApplicationStackName
        ComputeStackName = $ComputeStackName
        VpcId = $VpcId
        Region = $Region
        Profile = $Profile
        UpdatedAt = (Get-Date).ToString("o")
    }

    if ($manifest -and $manifest.PSObject.Properties.Name -contains 'ApplicationName') {
        $updatedManifest.ApplicationName = [string]$manifest.ApplicationName
    }
    if ($manifest -and $manifest.PSObject.Properties.Name -contains 'PrivateInstanceIP') {
        $updatedManifest.PrivateInstanceIP = [string]$manifest.PrivateInstanceIP
    }
    if ($manifest -and $manifest.PSObject.Properties.Name -contains 'PrivateSubnetId') {
        $updatedManifest.PrivateSubnetId = [string]$manifest.PrivateSubnetId
    }
    if ($manifest -and $manifest.PSObject.Properties.Name -contains 'PrivateSecurityGroupId') {
        $updatedManifest.PrivateSecurityGroupId = [string]$manifest.PrivateSecurityGroupId
    }
    if ($manifest -and $manifest.PSObject.Properties.Name -contains 'EFSSecurityGroupId') {
        $updatedManifest.EFSSecurityGroupId = [string]$manifest.EFSSecurityGroupId
    }
    Save-DeploymentManifest -DeploymentData $updatedManifest
    Write-Host "Deployment manifest saved to: $ManifestPath" -ForegroundColor DarkGray

    if (-not $Deploy) {
        Write-Host "Press Enter to continue with validation or Ctrl+C to cancel..." -ForegroundColor Yellow
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
        Write-Host "VALIDATION COMPLETE - PARALLEL DRY RUN SUMMARY" -ForegroundColor Yellow
        Write-Host "="*60 -ForegroundColor Yellow

        Write-Host "`nTemplate is valid and ready for deployment." -ForegroundColor Green
        Write-Host "`nParallel deployment pairing:" -ForegroundColor Cyan
        Write-Host "  - Deployment ID: $(if ([string]::IsNullOrWhiteSpace($DeploymentId)) { 'manual' } else { $DeploymentId })" -ForegroundColor White
        Write-Host "  - Application Stack: $ApplicationStackName" -ForegroundColor White
        Write-Host "  - Compute Stack: $ComputeStackName" -ForegroundColor White

        if ($stackExists) {
            Write-Host "`nNote: Stack '$ComputeStackName' already exists. Deployment would update it." -ForegroundColor Yellow
        } else {
            Write-Host "`nNote: Stack '$ComputeStackName' does not exist. Deployment would create it." -ForegroundColor Yellow
        }

        Write-Host "`nTo deploy, run deploy\02_compute_deploy.ps1 with -Deploy." -ForegroundColor Green
    } else {
        Write-Host "`n" + "="*60 -ForegroundColor Red
        Write-Host "DEPLOYING COMPUTE INFRASTRUCTURE" -ForegroundColor Red
        Write-Host "="*60 -ForegroundColor Red

        try {
            $computeArgs = @(
                "cloudformation", "deploy",
                "--template-file", $TemplateFile,
                "--stack-name", $ComputeStackName,
                "--region", $Region,
                "--profile", $Profile,
                "--capabilities", "CAPABILITY_NAMED_IAM",
                "--parameter-overrides",
                "VpcId=$VpcId",
                "ApplicationStackName=$ApplicationStackName",
                "--no-fail-on-empty-changeset"
            )

            & aws @computeArgs

            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Compute stack deployed successfully!" -ForegroundColor Green

                try {
                    $computeStack = aws cloudformation describe-stacks --stack-name $ComputeStackName --region $Region --profile $Profile --output json | ConvertFrom-Json
                    $computeOutputs = $computeStack.Stacks[0].Outputs

                    Write-Host "`nCompute Stack Outputs:" -ForegroundColor Green
                    foreach ($output in $computeOutputs) {
                        Write-Host "$($output.OutputKey): $($output.OutputValue)" -ForegroundColor Cyan
                    }
                } catch {
                    Write-Warning "Could not retrieve compute stack outputs"
                }

                Write-Host "`nParallel compute deployment complete for application stack '$ApplicationStackName'." -ForegroundColor Yellow
            } else {
                Write-Error "Compute stack deployment failed!"

                Write-Host "`nGetting deployment failure details..." -ForegroundColor Yellow
                $events = aws cloudformation describe-stack-events --stack-name $ComputeStackName --region $Region --profile $Profile --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' --output table 2>$null
                if ($events) {
                    Write-Host $events -ForegroundColor Red
                }

                Write-Host "`nCleaning up failed deployment..." -ForegroundColor Yellow
                $cleanupStack = aws cloudformation describe-stacks --stack-name $ComputeStackName --region $Region --profile $Profile --output json 2>$null | ConvertFrom-Json
                if ($cleanupStack -and $cleanupStack.Stacks.Count -gt 0) {
                    $cleanupStatus = $cleanupStack.Stacks[0].StackStatus
                    Remove-BadStackState -StackName $ComputeStackName -StackStatus $cleanupStatus | Out-Null
                }

                exit 1
            }
        } catch {
            Write-Error "Compute deployment failed: $_"
            exit 1
        }
    }

    Write-Host "`n" + "="*60 -ForegroundColor Green
    Write-Host "SCRIPT COMPLETED" -ForegroundColor Green
    Write-Host "="*60 -ForegroundColor Green
} finally {
    Pop-Location
}
