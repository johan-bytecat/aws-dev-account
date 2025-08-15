#!/usr/bin/env pwsh

# CloudFormation Template Validation Script
# Validates templates using AWS CLI for syntax, parameters, and best practices
#
# Usage Examples:
#   .\validate-templates.ps1                                    # Validate all *.yaml templates
#   .\validate-templates.ps1 -TemplatePattern "01-*.yaml"       # Validate specific pattern
#   .\validate-templates.ps1 -DetailedOutput                    # Show detailed parameter info
#   .\validate-templates.ps1 -SkipParameterValidation           # Skip parameter checks
#
# Features:
#   • AWS CloudFormation syntax validation
#   • Parameter validation and best practices
#   • Template best practices checking
#   • Comprehensive reporting with color coding
#   • Exit codes for CI/CD integration

param(
    [Parameter(Mandatory=$false)]
    [string]$TemplatePattern = "*.yaml",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "af-south-1",
    
    [Parameter(Mandatory=$false)]
    [string]$Profile = "bytecatdev",
    
    [Parameter(Mandatory=$false)]
    [switch]$DetailedOutput = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipParameterValidation = $false
)

# Set AWS profile environment variable
$env:AWS_PROFILE = $Profile

Write-Host "CloudFormation Template Validation" -ForegroundColor Green
Write-Host "===================================" -ForegroundColor Green
Write-Host "AWS Profile: $Profile" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host "Template Pattern: $TemplatePattern" -ForegroundColor Yellow

# Check if AWS CLI is configured
try {
    $identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
    Write-Host "AWS Account: $($identity.Account)" -ForegroundColor Green
} catch {
    Write-Error "AWS CLI not configured or credentials not available for profile: $Profile"
    exit 1
}

# Find CloudFormation templates
$templates = Get-ChildItem -Path $TemplatePattern | Where-Object { $_.Extension -eq ".yaml" -or $_.Extension -eq ".yml" }

if ($templates.Count -eq 0) {
    Write-Warning "No CloudFormation templates found matching pattern: $TemplatePattern"
    exit 1
}

Write-Host "`nFound $($templates.Count) template(s) to validate:" -ForegroundColor Blue
foreach ($template in $templates) {
    Write-Host "  - $($template.Name)" -ForegroundColor White
}

# Validation results tracking
$validationResults = @()
$totalTemplates = $templates.Count
$passedTemplates = 0
$failedTemplates = 0

# Function to validate template syntax
function Test-TemplateSyntax {
    param(
        [string]$TemplatePath
    )
    
    Write-Host "`n  Validating syntax..." -ForegroundColor Cyan
    
    try {
        $result = aws cloudformation validate-template --template-body file://$TemplatePath --region $Region --profile $Profile --output json 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            $templateInfo = $result | ConvertFrom-Json
            Write-Host "    ✓ Syntax validation passed" -ForegroundColor Green
            
            if ($DetailedOutput) {
                Write-Host "    Description: $($templateInfo.Description)" -ForegroundColor Gray
                Write-Host "    Parameters: $($templateInfo.Parameters.Count)" -ForegroundColor Gray
                Write-Host "    Capabilities: $($templateInfo.Capabilities -join ', ')" -ForegroundColor Gray
            }
            
            return @{
                Success = $true
                Info = $templateInfo
                Error = $null
            }
        } else {
            Write-Host "    ✗ Syntax validation failed" -ForegroundColor Red
            Write-Host "    Error: $result" -ForegroundColor Red
            
            return @{
                Success = $false
                Info = $null
                Error = $result
            }
        }
    } catch {
        Write-Host "    ✗ Syntax validation failed with exception" -ForegroundColor Red
        Write-Host "    Error: $_" -ForegroundColor Red
        
        return @{
            Success = $false
            Info = $null
            Error = $_
        }
    }
}

# Function to validate template parameters
function Test-TemplateParameters {
    param(
        [object]$TemplateInfo
    )
    
    Write-Host "`n  Validating parameters..." -ForegroundColor Cyan
    
    if (-not $TemplateInfo.Parameters -or $TemplateInfo.Parameters.Count -eq 0) {
        Write-Host "    ✓ No parameters to validate" -ForegroundColor Green
        return $true
    }
    
    $parameterIssues = @()
    
    foreach ($param in $TemplateInfo.Parameters) {
        # Check for required parameters without defaults
        if (-not $param.DefaultValue -and -not $param.NoEcho) {
            if ($DetailedOutput) {
                Write-Host "    ⚠ Parameter '$($param.ParameterKey)' has no default value" -ForegroundColor Yellow
            }
        }
        
        # Check parameter descriptions
        if (-not $param.Description -or $param.Description.Length -lt 10) {
            $parameterIssues += "Parameter '$($param.ParameterKey)' has insufficient description"
        }
        
        if ($DetailedOutput) {
            Write-Host "    Parameter: $($param.ParameterKey) ($($param.Description))" -ForegroundColor Gray
        }
    }
    
    if ($parameterIssues.Count -eq 0) {
        Write-Host "    ✓ Parameter validation passed" -ForegroundColor Green
        return $true
    } else {
        Write-Host "    ⚠ Parameter validation issues found:" -ForegroundColor Yellow
        foreach ($issue in $parameterIssues) {
            Write-Host "      - $issue" -ForegroundColor Yellow
        }
        return $false
    }
}

# Function to check template best practices
function Test-TemplateBestPractices {
    param(
        [string]$TemplatePath
    )
    
    Write-Host "`n  Checking best practices..." -ForegroundColor Cyan
    
    $content = Get-Content -Path $TemplatePath -Raw
    $issues = @()
    
    # Check for hardcoded values (excluding CloudFormation functions and references)
    if ($content -match "(?i)(password|secret|key)\s*:\s*[`"'][a-zA-Z0-9]{8,}[`"']" -and $content -notmatch "!Ref|!GetAtt|!Sub") {
        $issues += "Potential hardcoded secrets detected"
    }
    
    # Check for description
    if ($content -notmatch "(?m)^Description\s*:") {
        $issues += "Template missing Description field"
    }
    
    # Check for AWSTemplateFormatVersion
    if ($content -notmatch "(?m)^AWSTemplateFormatVersion\s*:") {
        $issues += "Template missing AWSTemplateFormatVersion"
    }
    
    # Check for resource naming conventions (lowercase at start of name)
    if ($content -match "(?i)Name\s*:\s*[`"']?[a-z][a-z-]*[`"']?" -and $content -notmatch "!Sub|!Ref|!GetAtt") {
        $issues += "Resource names should follow PascalCase convention"
    }
    
    # Check for outputs
    if ($content -notmatch "(?m)^Outputs\s*:") {
        $issues += "Template has no Outputs section (consider adding for reusability)"
    }
    
    # Check for tags
    if ($content -notmatch "(?i)Tags\s*:") {
        $issues += "Resources should include Tags for better management"
    }
    
    if ($issues.Count -eq 0) {
        Write-Host "    ✓ Best practices check passed" -ForegroundColor Green
        return $true
    } else {
        Write-Host "    ⚠ Best practices issues found:" -ForegroundColor Yellow
        foreach ($issue in $issues) {
            Write-Host "      - $issue" -ForegroundColor Yellow
        }
        return $false
    }
}

# Function to estimate template costs (if supported)
function Test-TemplateCosts {
    param(
        [string]$TemplatePath
    )
    
    Write-Host "`n  Estimating costs..." -ForegroundColor Cyan
    
    try {
        # Note: This requires the template to be deployable with default parameters
        # We'll skip this for now as it's complex to provide all required parameters
        Write-Host "    ⚠ Cost estimation skipped (requires parameter values)" -ForegroundColor Yellow
        return $true
    } catch {
        Write-Host "    ⚠ Cost estimation not available" -ForegroundColor Yellow
        return $true
    }
}

# Main validation loop
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "STARTING TEMPLATE VALIDATION" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

foreach ($template in $templates) {
    Write-Host "`n📄 Validating: $($template.Name)" -ForegroundColor Magenta
    Write-Host "─" * 50 -ForegroundColor Gray
    
    $templatePath = $template.FullName
    $templateResult = @{
        Name = $template.Name
        Path = $templatePath
        SyntaxValid = $false
        ParametersValid = $false
        BestPracticesValid = $false
        OverallValid = $false
        Errors = @()
        Warnings = @()
    }
    
    # 1. Syntax Validation
    $syntaxResult = Test-TemplateSyntax -TemplatePath $templatePath
    $templateResult.SyntaxValid = $syntaxResult.Success
    
    if (-not $syntaxResult.Success) {
        $templateResult.Errors += "Syntax validation failed: $($syntaxResult.Error)"
        $failedTemplates++
        $validationResults += $templateResult
        continue
    }
    
    # 2. Parameter Validation
    if (-not $SkipParameterValidation) {
        $templateResult.ParametersValid = Test-TemplateParameters -TemplateInfo $syntaxResult.Info
    } else {
        $templateResult.ParametersValid = $true
        Write-Host "`n  Skipping parameter validation..." -ForegroundColor Yellow
    }
    
    # 3. Best Practices Check
    $templateResult.BestPracticesValid = Test-TemplateBestPractices -TemplatePath $templatePath
    
    # 4. Cost Estimation (optional)
    Test-TemplateCosts -TemplatePath $templatePath | Out-Null
    
    # Overall result
    $templateResult.OverallValid = $templateResult.SyntaxValid -and $templateResult.ParametersValid -and $templateResult.BestPracticesValid
    
    if ($templateResult.OverallValid) {
        Write-Host "`n  ✅ Template validation PASSED" -ForegroundColor Green
        $passedTemplates++
    } else {
        Write-Host "`n  ❌ Template validation FAILED" -ForegroundColor Red
        $failedTemplates++
    }
    
    $validationResults += $templateResult
}

# Summary Report
Write-Host "`n" + "="*60 -ForegroundColor Blue
Write-Host "VALIDATION SUMMARY" -ForegroundColor Blue
Write-Host "="*60 -ForegroundColor Blue

Write-Host "`nOverall Results:" -ForegroundColor White
Write-Host "  Total Templates: $totalTemplates" -ForegroundColor White
Write-Host "  Passed: $passedTemplates" -ForegroundColor Green
Write-Host "  Failed: $failedTemplates" -ForegroundColor Red

Write-Host "`nDetailed Results:" -ForegroundColor White
foreach ($result in $validationResults) {
    $status = if ($result.OverallValid) { "✅ PASS" } else { "❌ FAIL" }
    $color = if ($result.OverallValid) { "Green" } else { "Red" }
    
    Write-Host "`n  $($result.Name): $status" -ForegroundColor $color
    Write-Host "    Syntax: $(if ($result.SyntaxValid) { '✓' } else { '✗' })" -ForegroundColor White
    Write-Host "    Parameters: $(if ($result.ParametersValid) { '✓' } else { '✗' })" -ForegroundColor White
    Write-Host "    Best Practices: $(if ($result.BestPracticesValid) { '✓' } else { '✗' })" -ForegroundColor White
    
    if ($result.Errors.Count -gt 0) {
        Write-Host "    Errors:" -ForegroundColor Red
        foreach ($errorMsg in $result.Errors) {
            Write-Host "      - $errorMsg" -ForegroundColor Red
        }
    }
}

# Recommendations
Write-Host "`nRecommendations:" -ForegroundColor Yellow
if ($failedTemplates -gt 0) {
    Write-Host "  • Fix syntax errors in failed templates before deployment" -ForegroundColor White
    Write-Host "  • Review parameter descriptions and defaults" -ForegroundColor White
    Write-Host "  • Add missing tags and outputs for better resource management" -ForegroundColor White
}
Write-Host "  • Test templates in a development environment before production" -ForegroundColor White
Write-Host "  • Use AWS CloudFormation linting tools like cfn-lint for deeper analysis" -ForegroundColor White
Write-Host "  • Consider using AWS CloudFormation Guard for policy-as-code validation" -ForegroundColor White

# Exit with appropriate code
Write-Host "`n" + "="*60 -ForegroundColor Blue
if ($failedTemplates -eq 0) {
    Write-Host "ALL TEMPLATES VALIDATION COMPLETED SUCCESSFULLY! 🎉" -ForegroundColor Green
    exit 0
} else {
    Write-Host "TEMPLATE VALIDATION COMPLETED WITH ERRORS! ⚠️" -ForegroundColor Red
    exit 1
}
Write-Host "="*60 -ForegroundColor Blue
