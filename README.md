# AWS DevCloud Infrastructure

## Refactored Clean Architecture (2025-08-15)

This repository contains a simplified, robust infrastructure deployment for AWS DevCloud using a clean 2-stack architecture.

## Quick Start

```powershell
# 1. Deploy network infrastructure
.\deploy-network.ps1 -KeyPairName "your-key-pair"

# 2. Upload initialization scripts
.\upload-scripts.ps1

# 3. Deploy your application
.\deploy-application.ps1 -KeyPairName "your-key-pair" -ApplicationName "kite-server"

# 4. Manage instances
.\manage-instances.ps1 -Action status
```

## Architecture

### Stack 1: Network Infrastructure (`01-network.yaml`)
**Core networking that supports multiple applications**
- VPC, Subnets, Internet Gateway, Route Tables
- VPN/NAT Gateway with WireGuard VPN (10.0.0.0/24)
- Security Groups (VPN/NAT, Private Instance, EFS)
- Private Route53 Hosted Zone
- S3 Scripts Bucket
- IAM roles for NAT instance

### Stack 2: Application Infrastructure (`02-application.yaml`)
**Application-specific resources (deploy multiple independently)**
- Private Application Instance (configurable IP)
- EFS FileSystem (mounted at /mnt/efs)
- S3 Data Bucket (per application)
- IAM roles for application instance

## Files

### Active Templates & Scripts
- 📄 `01-network.yaml` - Network infrastructure template
- 📄 `02-application.yaml` - Application infrastructure template
- 🔧 `deploy-network.ps1` - Deploy network stack
- 🔧 `deploy-application.ps1` - Deploy application stack
- 🔧 `upload-scripts.ps1` - Upload initialization scripts
- 🔧 `manage-instances.ps1` - Instance management (start/stop/status)
- 🔧 `destroy-infrastructure.ps1` - Clean teardown
- 📝 `refactor.md` - Refactor documentation

### Key Files
- 🔐 `bytecatdev1.pem` / `bytecatdev1.ppk` - SSH key pair
- 📁 `scripts/` - Instance initialization scripts
- 📁 `devcloud-route53/` - Route53 configurations

### Obsolete Files (Moved to `fix/`)
All old templates and scripts from the previous fragmented architecture have been moved to the `fix/` folder for reference.

## Network Configuration

- **VPC**: 172.16.0.0/16
- **Public Subnet**: 172.16.1.0/24 (VPN/NAT Gateway)
- **Private Subnet**: 172.16.2.0/24 (Application Instances)
- **WireGuard VPN**: 10.0.0.0/24 (VPN clients)
- **VPN/NAT Gateway**: 172.16.1.100 (fixed)
- **Application Instance**: 172.16.2.100 (configurable)

## Benefits of New Architecture

✅ **Simplified**: 2 stacks instead of 6+  
✅ **Decoupled**: Network exists independently of applications  
✅ **Scalable**: Deploy multiple applications on same network  
✅ **Maintainable**: Clean dependencies and resource grouping  
✅ **Complete**: All security rules and IAM policies properly defined  

## Instance Management

```powershell
# Check status of all instances
.\manage-instances.ps1 -Action status

# Start/stop specific instances
.\manage-instances.ps1 -Action stop -Instance vpn-nat
.\manage-instances.ps1 -Action start -Instance app -ApplicationStackName "devcloud-app-kite-server"

# Restart all instances
.\manage-instances.ps1 -Action restart -Instance all
```
2. **IAM Roles**: `.\deploy-iam-roles.ps1`
3. **VPN/NAT**: `.\deploy-phase2.ps1`
4. **Private Instance**: `.\deploy-phase3.ps1`

## Migration History

The IAM roles were successfully separated from the foundation stack into their own stack for easier management. All migration-related scripts and documentation are in the `fix/` folder.

## Key Points

- ✅ IAM roles are now in a separate stack for independent updates
- ✅ All instances are running with correct IAM permissions
- ✅ Zero downtime migration was achieved
- ✅ Current architecture is fully operational
