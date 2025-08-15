#!/usr/bin/env pwsh

# AWS DevCloud IAM Roles Import Script
# Imports existing IAM resources into the devcloud-iam-roles stack
# Use this when IAM resources already exist in AWS but need to be managed by CloudFormation

param(
    [Parameter(Mandatory=$false)]
    [string]$FoundationStackName = "devcloud-foundation",
    
    [Parameter(Mandatory=$false)]
    [string]$IAMStackName = "devcloud-iam-roles",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateHostedZoneId = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev"
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "AWS DevCloud IAM Roles Import" -ForegroundColor Green
Write-Host "=============================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Foundation Stack: $FoundationStackName" -ForegroundColor Yellow
Write-Host "IAM Stack: $IAMStackName" -ForegroundColor Yellow
if ($PrivateHostedZoneId) {
    Write-Host "Private Hosted Zone ID: $PrivateHostedZoneId" -ForegroundColor Yellow
} else {
    Write-Host "Private Hosted Zone: Will use from foundation stack" -ForegroundColor Yellow
}

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "Deploying to AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

# Check if foundation stack exists
try {
    aws cloudformation describe-stacks --stack-name $FoundationStackName --region $Region --profile $Profile --output json | Out-Null
    Write-Host "✓ Foundation stack '$FoundationStackName' found" -ForegroundColor Green
} catch {
    Write-Error "Foundation stack '$FoundationStackName' not found. Please deploy foundation infrastructure first."
    Write-Host "Run: .\deploy-phase1.ps1" -ForegroundColor Cyan
    exit 1
}

# Check if IAM stack already exists
Write-Host "`nChecking if IAM stack exists..." -ForegroundColor Blue
aws cloudformation describe-stacks --stack-name $IAMStackName --region $Region --profile $Profile --output json 2>$null | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Warning "IAM stack '$IAMStackName' already exists. This script is for importing existing resources into a new stack."
    Write-Host "If you want to update the existing stack, use: .\deploy-iam-roles.ps1" -ForegroundColor Cyan
    Read-Host "Press Enter to continue with import anyway, or Ctrl+C to cancel"
} else {
    Write-Host "✓ IAM stack '$IAMStackName' does not exist - ready for import" -ForegroundColor Green
}

# Verify IAM resources exist in AWS
Write-Host "`nVerifying existing IAM resources..." -ForegroundColor Blue

$requiredRoles = @("DevCloud-VPN-NAT-Role", "DevCloud-Private-Instance-Role", "DevCloud-Instance-Management-Role")
$requiredProfiles = @("DevCloud-VPN-NAT-Role", "DevCloud-Private-Instance-Role")

$allResourcesExist = $true

foreach ($roleName in $requiredRoles) {
    aws iam get-role --role-name $roleName --profile $Profile --output json 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Found IAM Role: $roleName" -ForegroundColor Green
    } else {
        Write-Host "✗ IAM Role '$roleName' not found" -ForegroundColor Red
        $allResourcesExist = $false
    }
}

foreach ($profileName in $requiredProfiles) {
    aws iam get-instance-profile --instance-profile-name $profileName --profile $Profile --output json 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Found Instance Profile: $profileName" -ForegroundColor Green
    } else {
        Write-Host "✗ Instance Profile '$profileName' not found" -ForegroundColor Red
        $allResourcesExist = $false
    }
}

if (-not $allResourcesExist) {
    Write-Host "`nSome IAM resources are missing. Attempting to create missing instance profiles..." -ForegroundColor Yellow
    
    foreach ($profileName in $requiredProfiles) {
        aws iam get-instance-profile --instance-profile-name $profileName --profile $Profile --output json 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Creating missing instance profile: $profileName" -ForegroundColor Blue
            
            # Create instance profile
            aws iam create-instance-profile --instance-profile-name $profileName --profile $Profile
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Created instance profile: $profileName" -ForegroundColor Green
                
                # Add role to instance profile
                aws iam add-role-to-instance-profile --instance-profile-name $profileName --role-name $profileName --profile $Profile
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ Added role to instance profile: $profileName" -ForegroundColor Green
                } else {
                    Write-Error "Failed to add role to instance profile: $profileName"
                    exit 1
                }
            } else {
                Write-Error "Failed to create instance profile: $profileName"
                exit 1
            }
        }
    }
    
    Write-Host "`nRe-verifying all resources exist..." -ForegroundColor Blue
    $allResourcesExist = $true
    
    foreach ($roleName in $requiredRoles) {
        aws iam get-role --role-name $roleName --profile $Profile --output json 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✗ IAM Role '$roleName' still not found" -ForegroundColor Red
            $allResourcesExist = $false
        }
    }
    
    foreach ($profileName in $requiredProfiles) {
        aws iam get-instance-profile --instance-profile-name $profileName --profile $Profile --output json 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✗ Instance Profile '$profileName' still not found" -ForegroundColor Red
            $allResourcesExist = $false
        }
    }
    
    if (-not $allResourcesExist) {
        Write-Error "Unable to create all required IAM resources."
        exit 1
    } else {
        Write-Host "✓ All IAM resources are now available for import" -ForegroundColor Green
    }
}

# Create resource import mapping
Write-Host "`nCreating resource import mapping..." -ForegroundColor Blue

$importFile = "iam-resources-import.json"
$resourceMapping = @(
    @{
        "ResourceType" = "AWS::IAM::Role"
        "LogicalResourceId" = "VPNNATRole"
        "ResourceIdentifier" = @{
            "RoleName" = "DevCloud-VPN-NAT-Role"
        }
    },
    @{
        "ResourceType" = "AWS::IAM::Role"
        "LogicalResourceId" = "PrivateInstanceRole"
        "ResourceIdentifier" = @{
            "RoleName" = "DevCloud-Private-Instance-Role"
        }
    },
    @{
        "ResourceType" = "AWS::IAM::Role"
        "LogicalResourceId" = "InstanceManagementRole"
        "ResourceIdentifier" = @{
            "RoleName" = "DevCloud-Instance-Management-Role"
        }
    },
    @{
        "ResourceType" = "AWS::IAM::InstanceProfile"
        "LogicalResourceId" = "VPNNATInstanceProfile"
        "ResourceIdentifier" = @{
            "InstanceProfileName" = "DevCloud-VPN-NAT-Role"
        }
    },
    @{
        "ResourceType" = "AWS::IAM::InstanceProfile"
        "LogicalResourceId" = "PrivateInstanceProfile"
        "ResourceIdentifier" = @{
            "InstanceProfileName" = "DevCloud-Private-Instance-Role"
        }
    }
)

# Write import mapping to file with proper JSON formatting
$jsonContent = $resourceMapping | ConvertTo-Json -Depth 4 -Compress
$jsonContent | Out-File -FilePath $importFile -Encoding UTF8 -NoNewline
Write-Host "✓ Created import mapping file: $importFile" -ForegroundColor Green

# Debug: Show the JSON content
Write-Host "`nGenerated JSON content:" -ForegroundColor Blue
Write-Host $jsonContent -ForegroundColor Gray

# Import IAM Resources into new stack
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "IMPORTING IAM RESOURCES INTO CLOUDFORMATION STACK" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

try {
    Write-Host "Creating import change set..." -ForegroundColor Blue
    
    # Check for any existing change sets and clean them up
    Write-Host "Checking for existing change sets..." -ForegroundColor Blue
    $existingChangeSets = aws cloudformation list-change-sets --stack-name $IAMStackName --region $Region --profile $Profile --output json 2>$null | ConvertFrom-Json
    if ($existingChangeSets -and $existingChangeSets.Summaries) {
        Write-Host "Found existing change sets. Cleaning up..." -ForegroundColor Yellow
        $existingChangeSets.Summaries | ForEach-Object {
            aws cloudformation delete-change-set --change-set-name $_.ChangeSetName --stack-name $IAMStackName --region $Region --profile $Profile 2>$null
        }
        Start-Sleep -Seconds 2
    }
    
    # Step 1: Create change set for import
    $changeSetName = "import-iam-resources-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    
    $importArgs = @(
        "cloudformation", "create-change-set",
        "--stack-name", $IAMStackName,
        "--change-set-name", $changeSetName,
        "--change-set-type", "IMPORT",
        "--template-body", "file://iam-roles-import.yaml",
        "--region", $Region,
        "--profile", $Profile,
        "--capabilities", "CAPABILITY_NAMED_IAM",
        "--parameters", "ParameterKey=FoundationStackName,ParameterValue=$FoundationStackName", "ParameterKey=PrivateHostedZoneId,ParameterValue=$PrivateHostedZoneId",
        "--resources-to-import", "file://$importFile",
        "--output", "table"
    )
    
    & aws @importArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Import change set created successfully!" -ForegroundColor Green
        
        # Wait for change set creation to complete
        Write-Host "`nWaiting for change set creation to complete..." -ForegroundColor Blue
        aws cloudformation wait change-set-create-complete --change-set-name $changeSetName --stack-name $IAMStackName --region $Region --profile $Profile
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Change set creation completed!" -ForegroundColor Green
            
            # Step 2: Execute the change set
            Write-Host "`nExecuting import change set..." -ForegroundColor Blue
            aws cloudformation execute-change-set --change-set-name $changeSetName --stack-name $IAMStackName --region $Region --profile $Profile
        } else {
            # Change set creation failed - get details
            Write-Host "`nChange set creation failed. Getting error details..." -ForegroundColor Red
            $changeSetDetails = aws cloudformation describe-change-set --change-set-name $changeSetName --stack-name $IAMStackName --region $Region --profile $Profile --output json | ConvertFrom-Json
            
            if ($changeSetDetails.StatusReason) {
                Write-Host "Error Reason: $($changeSetDetails.StatusReason)" -ForegroundColor Red
            }
            
            if ($changeSetDetails.Changes) {
                Write-Host "`nChange Set Details:" -ForegroundColor Yellow
                $changeSetDetails.Changes | ForEach-Object {
                    Write-Host "- $($_.ResourceChange.LogicalResourceId): $($_.ResourceChange.Action)" -ForegroundColor Gray
                }
            }
            
            # Clean up failed change set
            Write-Host "`nCleaning up failed change set..." -ForegroundColor Blue
            aws cloudformation delete-change-set --change-set-name $changeSetName --stack-name $IAMStackName --region $Region --profile $Profile 2>$null
            
            Write-Error "Change set creation failed. See error details above."
            exit 1
        }
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Import change set execution initiated!" -ForegroundColor Green
            
            # Wait for import to complete
            Write-Host "`nWaiting for import to complete..." -ForegroundColor Yellow
            aws cloudformation wait stack-import-complete --stack-name $IAMStackName --region $Region --profile $Profile
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Import completed successfully!" -ForegroundColor Green
                
                # Step 3: Update stack to add outputs
                Write-Host "`nUpdating stack to add outputs..." -ForegroundColor Blue
                aws cloudformation deploy --template-file iam-roles.yaml --stack-name $IAMStackName --region $Region --profile $Profile --capabilities CAPABILITY_NAMED_IAM --parameter-overrides "FoundationStackName=$FoundationStackName" "PrivateHostedZoneId=$PrivateHostedZoneId"
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ Stack updated with outputs successfully!" -ForegroundColor Green
                    
                    # Get IAM stack outputs
                    Write-Host "`nIAM Stack Outputs:" -ForegroundColor Blue
                    aws cloudformation describe-stacks --stack-name $IAMStackName --region $Region --profile $Profile --query 'Stacks[0].Outputs' --output table
                } else {
                    Write-Warning "Import succeeded but failed to add outputs. You can add them later using deploy-iam-roles.ps1"
                }
            } else {
                Write-Error "Import operation failed or timed out"
                exit 1
            }
        } else {
            Write-Error "Failed to execute import change set"
            exit 1
        }
    } else {
        Write-Error "Failed to create import change set"
        exit 1
    }
} catch {
    Write-Error "Error importing IAM resources: $_"
    exit 1
} finally {
    # Clean up import file
    if (Test-Path $importFile) {
        Remove-Item $importFile -Force
        Write-Host "✓ Cleaned up import file" -ForegroundColor Green
    }
}

# Next Steps
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "NEXT STEPS" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

Write-Host "`nIAM resources import completed successfully!" -ForegroundColor Green
Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Upload scripts to S3 bucket:" -ForegroundColor White
Write-Host "   .\upload-scripts.ps1 -StackName $FoundationStackName" -ForegroundColor Cyan
Write-Host "`n2. Deploy Phase 2 (compute resources):" -ForegroundColor White
Write-Host "   .\deploy-phase2.ps1 -KeyPairName <your-key-pair> -FoundationStackName $FoundationStackName -IAMStackName $IAMStackName" -ForegroundColor Cyan
Write-Host "`n3. Verify all cross-stack references work correctly" -ForegroundColor White

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "IAM RESOURCES IMPORT COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "="*60 -ForegroundColor Green
