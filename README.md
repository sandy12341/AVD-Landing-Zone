# Azure Virtual Desktop + Landing Zone

Production-ready Azure Virtual Desktop deployment with Landing Zone architecture. Includes host pool provisioning, FSLogix profile containers, Entra ID join, network segmentation, and monitoring — aligned with Cloud Adoption Framework (CAF) best practices.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsandy12341%2FAVD-Landing-Zone%2Fmaster%2Finfra%2Fazuredeploy.json)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Resource Group: rg-avd-<prefix>-<env>                      │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────────────────────┐  │
│  │  VNet            │  │  Host Pool + Workspace          │  │
│  │  10.20.0.0/16    │  │  ├─ Desktop and/or RemoteApp    │  │
│  │  ├─ snet-hosts   │  │  └─ Start VM on Connect         │  │
│  │  │  10.20.1.0/24 │  └─────────────────────────────────┘  │
│  │  └─ snet-pe      │                                       │
│  │     10.20.2.0/24 │  ┌─────────────────────────────────┐  │
│  └─────────────────┘  │  Session Host VMs                │  │
│                        │  ├─ Windows 11 Multi-Session     │  │
│  ┌─────────────────┐  │  ├─ Entra ID Joined              │  │
│  │  FSLogix Storage │  │  └─ AVD Agent (DSC)              │  │
│  │  (Azure Files)   │  └─────────────────────────────────┘  │
│  └─────────────────┘                                        │
│                        ┌─────────────────────────────────┐  │
│  ┌─────────────────┐  │  Monitoring                      │  │
│  │  NSG             │  │  Log Analytics Workspace         │  │
│  │  RDP from VNet   │  └─────────────────────────────────┘  │
│  └─────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
```

## Features

- **Delivery Modes**: `PersonalDesktop`, `PooledRemoteApp`, and `PooledDesktopAndRemoteApp`, with legacy `hostPoolType` fallback for existing desktop-only deployments
- **Host Pool**: Pooled (BreadthFirst) or Personal, with Start VM on Connect
- **Session Hosts**: Windows 11 24H2 Multi-Session, Entra ID joined, System Assigned Managed Identity
- **FSLogix**: Azure Files share for user profile containers (Entra ID Kerberos auth, VNet-restricted)
- **Networking**: Dedicated VNet with NSG, separate subnets for hosts and private endpoints
- **Monitoring**: Log Analytics workspace for diagnostics
- **Application Publishing**: Desktop app group, RemoteApp app group, or both from the same template
- **Security**: NSG restricts RDP to VNet only, TLS 1.2 enforced on storage, no shared key access, and a CSE-driven AVD agent install using a GitHub-hosted script to avoid Windows command-line length limits

## Prerequisites

- Azure subscription with **Owner** access (required for auto role assignments; Contributor is sufficient if `avdUserObjectId` is left empty)
- Resource provider `Microsoft.DesktopVirtualization` registered
- Resource provider `Microsoft.Storage` registered (for FSLogix)

## Quick Start

### Option 1: Deploy to Azure (Portal)

Click the **Deploy to Azure** button above for a guided deployment experience.

Important:

- `storageAccountName` is a required free-form field in the portal
- you must enter a globally unique name during deployment
- the template no longer provides a default storage account name

### Option 2: Azure CLI

```bash
# Create resource group
az group create --name rg-avd-avd1-dev --location westus2

# Deploy
az deployment group create \
  --resource-group rg-avd-avd1-dev \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json \
  --parameters adminPassword='<secure-password>' storageAccountName='<globally-unique-storage-name>'
```

### Option 3: PowerShell

```powershell
# Create resource group
New-AzResourceGroup -Name "rg-avd-avd1-dev" -Location "westus2"

# Deploy
New-AzResourceGroupDeployment `
  -ResourceGroupName "rg-avd-avd1-dev" `
  -TemplateFile "infra/main.bicep" `
  -TemplateParameterFile "infra/main.parameters.json" `
  -adminPassword (Read-Host -AsSecureString "Admin Password") `
  -storageAccountName "<globally-unique-storage-name>"
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `deploymentPrefix` | string | `avd1` | Naming prefix (max 6 chars) |
| `environment` | string | `dev` | Environment: dev, test, prod |
| `sessionHostCount` | int | `1` | Number of session host VMs (1-10) |
| `vmSize` | string | `Standard_D2ads_v5` | VM SKU for session hosts |
| `avdMode` | string | _(empty)_ | Preferred routing model: `PersonalDesktop`, `PooledRemoteApp`, or `PooledDesktopAndRemoteApp`. Leave empty to preserve the legacy desktop-only behavior from `hostPoolType`. |
| `hostPoolType` | string | `Pooled` | Legacy fallback for desktop-only deployments when `avdMode` is empty |
| `adminUsername` | string | `avdadmin` | Local admin username |
| `adminPassword` | secureString | - | Local admin password (required) |
| `deployFSLogix` | bool | `true` | Deploy FSLogix Azure Files storage |
| `storageAccountName` | string | - | Required unique storage account name for FSLogix (globally unique, 3-24 chars) |
| `deployMonitoring` | bool | `true` | Deploy Log Analytics workspace |
| `avdUserObjectId` | string | _(empty)_ | Entra Object ID of user to grant AVD access (leave empty to skip). Get via: `az ad user show --id user@domain.com --query id -o tsv` |
| `remoteApps` | array | `[]` | RemoteApp definitions used when `avdMode` publishes RemoteApps |

### RemoteApp example

```json
[
  {
    "name": "notepad",
    "friendlyName": "Notepad",
    "filePath": "C:\\Windows\\System32\\notepad.exe"
  },
  {
    "name": "mspaint",
    "friendlyName": "Paint",
    "filePath": "C:\\Windows\\System32\\mspaint.exe"
  }
]
```

### Mode-specific sample parameter files

- `infra/samples/main.personaldesktop.parameters.json`
- `infra/samples/main.pooledremoteapp.parameters.json`
- `infra/samples/main.pooleddesktopandremoteapp.parameters.json`

Use one of the sample files directly with Azure CLI or PowerShell and override only the environment-specific secure values:

```bash
az deployment group create \
  --resource-group rg-avd-avd1-dev \
  --template-file infra/main.bicep \
  --parameters @infra/samples/main.pooleddesktopandremoteapp.parameters.json \
  --parameters adminPassword='<secure-password>' \
               storageAccountName='<globally-unique-storage-name>' \
               avdUserObjectId='<entra-object-id>'
```

## Connecting to AVD

- **Web Client**: [https://client.wvd.microsoft.com](https://client.wvd.microsoft.com/arm/webclient/index.html)
- **Windows App / RD Client**: [Download](https://aka.ms/AVDClientDownload)

## Related

- [Azure Virtual Desktop Documentation](https://learn.microsoft.com/azure/virtual-desktop/)
- [AVD Accelerator](https://github.com/Azure/avdaccelerator)
- [Cloud Adoption Framework](https://learn.microsoft.com/azure/cloud-adoption-framework/)

## License

MIT
