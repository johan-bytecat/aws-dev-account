#!/usr/bin/env pwsh

# AWS DevCloud Compute Infrastructure Deployment Script (DevCloud Version)
# Deploys: Compute Security Group and IAM Role
# Defaults to validation mode. Use -Deploy to actually deploy.

param(
    [Parameter(Mandatory=$false)]
    [string]$NetworkStackName = "devcloud-network",

    [Parameter(Mandatory=$false)]
    [string]$ApplicationStackName = "",  # Will be auto-generated if not provided

    [Parameter(Mandatory=$false)]
    [string]$ApplicationName = "kite-server",  # To match application stack naming

    [Parameter(Mandatory=$false)]
    [string]$ComputeStackName = "",  # Will be auto-generated if not provided

    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",

    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev",

    [Parameter(Mandatory=$false)]
    [switch]$Deploy
)

# Auto-generate application stack name if not provided
if ([string]::IsNullOrEmpty($ApplicationStackName)) {
    $ApplicationStackName = "devcloud-app-$ApplicationName"
}

# Auto-generate compute stack name if not provided
if ([string]::IsNullOrEmpty($ComputeStackName)) {
    $ComputeStackName = "devcloud-compute"
}

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud Compute Infrastructure Deployment (DevCloud Version)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Mode: $(if ($Deploy) { 'DEPLOY' } else { 'VALIDATE ONLY' })" -ForegroundColor $(if ($Deploy) { 'Red' } else { 'Yellow' })
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Network Stack: $NetworkStackName" -ForegroundColor Yellow
Write-Host "Application Stack: $ApplicationStackName" -ForegroundColor Yellow
Write-Host "Compute Stack: $ComputeStackName" -ForegroundColor Yellow

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "Deploying to AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
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
        Write-Error "Network stack is in state: $stackStatus (not ready for compute deployment)"
        exit 1
    }
} catch {
    Write-Error "Network stack '$NetworkStackName' not found in region $Region"
    Write-Host "Deploy network infrastructure first with: .\deploy-network.ps1" -ForegroundColor Yellow
    exit 1
}

# Check if application stack exists
try {
    $appStack = aws cloudformation describe-stacks --stack-name $ApplicationStackName --region $Region --profile $Profile --output json | ConvertFrom-Json
    Write-Host "✓ Application stack '$ApplicationStackName' found" -ForegroundColor Green

    # Check if application stack is in a good state
    $stackStatus = $appStack.Stacks[0].StackStatus
    if ($stackStatus -eq "CREATE_COMPLETE" -or $stackStatus -eq "UPDATE_COMPLETE") {
        Write-Host "Application stack status: $stackStatus ✓" -ForegroundColor Green
    } else {
        Write-Error "Application stack is in state: $stackStatus (not ready for compute deployment)"
        exit 1
    }
} catch {
    Write-Error "Application stack '$ApplicationStackName' not found in region $Region"
    Write-Host "Deploy application infrastructure first with: .\deploy-application-devcloud.ps1 -KeyPairName <keypair>" -ForegroundColor Yellow
    exit 1
}

# Helper function to clean up stacks in bad states
function Cleanup-BadStackState {
    param(
        [string]$StackName,
        [string]$StackStatus
    )
    
    $badStates = @("REVIEW_IN_PROGRESS", "CREATE_FAILED", "ROLLBACK_COMPLETE", "ROLLBACK_FAILED", "DELETE_FAILED")
    
    if ($StackStatus -in $badStates) {
        Write-Warning "Stack '$StackName' is in state: $StackStatus"
        Write-Host "Cleaning up stack before proceeding..." -ForegroundColor Yellow
        
        # Delete the stack
        aws cloudformation delete-stack --stack-name $StackName --region $Region --profile $Profile 2>$null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Waiting for stack deletion to complete..." -ForegroundColor Yellow
            aws cloudformation wait stack-delete-complete --stack-name $StackName --region $Region --profile $Profile 2>$null
            Write-Host "✓ Stack cleanup completed" -ForegroundColor Green
            return $true
        } else {
            Write-Error "Failed to delete stack in bad state. Manual intervention may be required."
            return $false
        }
    }
    return $true
}

# Check if compute stack already exists and handle bad states
$stackExists = $false
$computeStackStatus = $null
try {
    $existingStack = aws cloudformation describe-stacks --stack-name $ComputeStackName --region $Region --profile $Profile --output json 2>$null | ConvertFrom-Json
    if ($existingStack -and $existingStack.Stacks.Count -gt 0) {
        $computeStackStatus = $existingStack.Stacks[0].StackStatus
        Write-Host "Existing compute stack found with status: $computeStackStatus" -ForegroundColor Yellow
        
        # Clean up if in bad state
        if (-not (Cleanup-BadStackState -StackName $ComputeStackName -StackStatus $computeStackStatus)) {
            exit 1
        }
        
        # Re-check if stack still exists after cleanup
        try {
            $recheckStack = aws cloudformation describe-stacks --stack-name $ComputeStackName --region $Region --profile $Profile --output json 2>$null | ConvertFrom-Json
            if ($recheckStack -and $recheckStack.Stacks.Count -gt 0) {
                $computeStackStatus = $recheckStack.Stacks[0].StackStatus
                $stackExists = $true
            }
        } catch {
            $stackExists = $false
        }
    }
} catch {
    # Stack doesn't exist, which is fine
    $stackExists = $false
}

if (-not $Deploy) {
    Write-Host "Press Enter to continue with validation or Ctrl+C to cancel..." -ForegroundColor Yellow
} else {
    Write-Host "Press Enter to continue with DEPLOYMENT or Ctrl+C to cancel..." -ForegroundColor Red
}
Read-Host

# Validate template
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "VALIDATING TEMPLATE: 03-compute-devcloud.yaml" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    $validateArgs = @(
        "cloudformation", "validate-template",
        "--template-body", "file://03-compute-devcloud.yaml",
        "--region", $Region,
        "--profile", $Profile
    )

    $validationResult = & aws @validateArgs
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
    # Validation-only mode: Just show what would be created
    Write-Host "`n" + "="*60 -ForegroundColor Yellow
    Write-Host "VALIDATION COMPLETE - DRY RUN SUMMARY" -ForegroundColor Yellow
    Write-Host "="*60 -ForegroundColor Yellow
    
    Write-Host "`nTemplate is valid and ready for deployment." -ForegroundColor Green
    Write-Host "`nResources that would be created:" -ForegroundColor Cyan
    Write-Host "  - ComputeSecurityGroup (AWS::EC2::SecurityGroup)" -ForegroundColor White
    Write-Host "  - ComputeInstanceRole (AWS::IAM::Role)" -ForegroundColor White
    Write-Host "  - ComputeInstanceProfile (AWS::IAM::InstanceProfile)" -ForegroundColor White
    
    Write-Host "`nParameters:" -ForegroundColor Cyan
    Write-Host "  - NetworkStackName: $NetworkStackName" -ForegroundColor White
    Write-Host "  - ApplicationStackName: $ApplicationStackName" -ForegroundColor White
    
    if ($stackExists) {
        Write-Host "`nNote: Stack '$ComputeStackName' already exists. Deployment would update it." -ForegroundColor Yellow
    } else {
        Write-Host "`nNote: Stack '$ComputeStackName' does not exist. Deployment would create it." -ForegroundColor Yellow
    }
    
    Write-Host "`nTo deploy, run: .\deploy-compute-devcloud.ps1 -Deploy" -ForegroundColor Green

} else {
    # Deploy mode
    Write-Host "`n" + "="*60 -ForegroundColor Red
    Write-Host "DEPLOYING COMPUTE INFRASTRUCTURE" -ForegroundColor Red
    Write-Host "="*60 -ForegroundColor Red

    try {
        Write-Host "Deploying compute stack..." -ForegroundColor Red

        $computeArgs = @(
            "cloudformation", "deploy",
            "--template-file", "03-compute-devcloud.yaml",
            "--stack-name", $ComputeStackName,
            "--region", $Region,
            "--profile", $Profile,
            "--capabilities", "CAPABILITY_NAMED_IAM",
            "--parameter-overrides",
            "NetworkStackName=$NetworkStackName",
            "ApplicationStackName=$ApplicationStackName",
            "--no-fail-on-empty-changeset"
        )

        & aws @computeArgs

        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Compute stack deployed successfully!" -ForegroundColor Green

            # Get compute stack outputs
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

            Write-Host "`nNext steps:" -ForegroundColor Yellow
            Write-Host "1. The compute security group and IAM role are now available for use." -ForegroundColor Cyan
            Write-Host "2. Use the role ARN and profile name when launching compute instances." -ForegroundColor Cyan

        } else {
            Write-Error "Compute stack deployment failed!"
            
            # Get failure details
            Write-Host "`nGetting deployment failure details..." -ForegroundColor Yellow
            $events = aws cloudformation describe-stack-events --stack-name $ComputeStackName --region $Region --profile $Profile --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' --output table 2>$null
            if ($events) {
                Write-Host $events -ForegroundColor Red
            }
            
            # Clean up failed stack
            Write-Host "`nCleaning up failed deployment..." -ForegroundColor Yellow
            $cleanupStack = aws cloudformation describe-stacks --stack-name $ComputeStackName --region $Region --profile $Profile --output json 2>$null | ConvertFrom-Json
            if ($cleanupStack -and $cleanupStack.Stacks.Count -gt 0) {
                $cleanupStatus = $cleanupStack.Stacks[0].StackStatus
                Cleanup-BadStackState -StackName $ComputeStackName -StackStatus $cleanupStatus | Out-Null
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
