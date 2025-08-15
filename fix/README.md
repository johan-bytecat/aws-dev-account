# IAM Migration Fix Scripts and Templates

This folder contains all the scripts and templates that were created during the IAM separation migration process. These are kept for reference and troubleshooting purposes.

## Migration Background

The goal was to separate IAM roles from `foundation-infrastructure.yaml` into a separate `iam-roles.yaml` stack to allow independent updates of IAM policies.

## Files in this folder:

### Templates
- **`iam-roles-import.yaml`** - Import-specific IAM template (without outputs to avoid conflicts)
- **`iam-roles-new.yaml`** - IAM template with "-v2" suffixed resource names to avoid naming conflicts

### Migration Scripts
- **`import-iam-roles.ps1`** - Script to import existing IAM resources into CloudFormation
- **`migrate-iam-safe.ps1`** - Safe migration approach to preserve running instances
- **`migrate-iam-manual.ps1`** - Manual IAM profile assignment (used successfully)
- **`migrate-iam-complete.ps1`** - Complete migration orchestration script
- **`deploy-iam-roles-new.ps1`** - Deploy new IAM stack with v2 resource names

### Stack Update Scripts
- **`update-compute-stacks.ps1`** - Update compute stacks to reference new IAM stack
- **`fix-compute-stacks.ps1`** - Attempt to fix CloudFormation stack state issues
- **`sync-cloudformation.ps1`** - Sync CloudFormation state with actual AWS resources

### Cleanup Scripts
- **`remove-iam-from-foundation.ps1`** - Remove IAM resources from foundation template

### Documentation
- **`MIGRATION-SUCCESS.md`** - Documentation of successful migration steps

## Current Status

✅ **Migration Completed Successfully**
- New IAM stack (`devcloud-iam-roles`) deployed with "-v2" suffixed resources
- Both compute instances manually updated with new IAM roles
- Instances are running with correct permissions
- No downtime occurred

## Issues Encountered

- CloudFormation import failed due to existing resource names
- CloudFormation stack updates failed due to IAM instance profile association conflicts
- Manual IAM profile updates were required to avoid instance replacement

## Resolution

The manual approach (`migrate-iam-manual.ps1`) was used successfully:
1. Created new IAM stack with different resource names
2. Manually attached new IAM instance profiles to existing instances
3. Verified instances have correct permissions
4. CloudFormation stack state issues remain but instances are working correctly

## Next Steps

The main deployment scripts in the parent folder should be used for ongoing operations:
- `deploy-iam-roles.ps1` - For IAM stack updates
- `deploy-phase2.ps1` - For VPN/NAT stack operations
- `deploy-phase3.ps1` - For private instance operations

## Important Notes

- Instances are currently using IAM roles with "-v2" suffix
- CloudFormation stack state may show drift but actual resources are working correctly
- Any future IAM changes should be made through the `iam-roles.yaml` template in the parent folder
