# Azure Virtual Desktop + Landing Zone

Production-ready Azure Virtual Desktop deployment with Landing Zone architecture. Includes validated `PersonalDesktop`, `PooledRemoteApp`, and `PooledDesktopAndRemoteApp` delivery modes, FSLogix profile containers, Entra ID join, network segmentation, and monitoring.

## Quick Deploy Options

### Option 1: Managed Application (Recommended for Multi-Tenant) ⭐

Deploy via Azure Managed Application portal with dynamic VNet/subnet dropdowns:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Solutions/ApplicationDefinition/avd-existing-network)

**Benefits:**
- Multi-tenant self-service deployment
- Portal wizard with VNet and subnet dropdowns (no manual parameter entry)
- Each user deploys to their own subscription/resources
- Managed identity with automatic RBAC for resource access

### Option 2: ARM Template Deployment

Deploy directly from GitHub ARM template:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsandy12341%2FAVD-Landing-Zone%2Fmaster%2Finfra%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fsandy12341%2FAVD-Landing-Zone%2Fmaster%2Finfra%2FcreateUiDefinition.json)

**Note:** Requires manual parameter entry; VNet/subnet selection via text fields.

---

## Managed Application Architecture

The repository includes pre-built **Azure Managed Application** infrastructure (`infra/managedapp/`) that provides a portal-driven deployment experience with dynamic VNet/subnet selection via dropdowns.

### Managed App Files

- **`mainTemplate.bicep`** - AVD infrastructure template (accepts existing VNet/subnets)
- **`createUiDefinition.json`** - Portal wizard UI (5-step wizard with ArmApiControl dropdowns)
- **`deployDefinition.bicep`** - Infrastructure-as-code for publishing the definition
- **`dist/app.zip`** - Complete deployment package (hosted as GitHub release asset)

### How It Works

1. **User clicks Deploy button** → Portal opens managed application wizard
2. **User authenticates** with their Azure credentials
3. **Portal populates dropdowns**:
   - Queries their subscriptions via ArmApiControl
   - Lists VNets in selected subscription
   - Lists subnets in selected VNet
4. **User selects or enters**:
   - Host pool name, instance count, VM size
   - AVD delivery mode (PersonalDesktop / PooledRemoteApp)
   - Admin credentials
   - FSLogix and monitoring options
   - (Optional) User object ID for RBAC access assignment
5. **Resources deployed** to user's subscription in their selected resource group

### Republishing the Managed Application

To republish to a different Azure AD tenant or subscription:

```bash
# 1. Update Bicep templates as needed
# 2. Recompile to JSON
az bicep build --file infra/managedapp/mainTemplate.bicep --outfile infra/managedapp/dist/mainTemplate.json
az bicep build --file infra/managedapp/deployDefinition.bicep --outfile infra/managedapp/dist/deployDefinition.json

# 3. Create new app.zip package
$files = @(
  'infra/managedapp/dist/mainTemplate.json',
  'infra/managedapp/dist/createUiDefinition.json'
) | ForEach-Object { Get-Item $_ }
Compress-Archive -Path $files -DestinationPath 'infra/managedapp/dist/app.zip' -Force

# 4. Upload app.zip to your blob storage or GitHub release
# 5. Deploy managedApplicationDefinition
$packageUri = "https://your-storage-account.blob.core.windows.net/container/app.zip"
az deployment group create \
  -g <your-definition-rg> \
  --template-file infra/managedapp/deployDefinition.bicep \
  --parameters packageFileUri="$packageUri" principalId="<your-principal-id>"
```

### Multi-Tenant Deployment

To enable users in other Azure AD tenants to deploy:

1. **Publish in a shared subscription** managed by your organization
2. **Generate Deploy button** with the published `applicationDefinitionId`
3. **Share link** — users authenticate with their own credentials
4. **Each user deploys** to their own subscription with their own resources

No cross-tenant permissions needed — each user manages their own deployed resources independently.

---

```
┌─────────────────────────────────────────────────────────────┐
│  Resource Group: rg-avd-<prefix>-<env>                      │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────────────────────┐  │
│  │  Existing VNet   │  │  Host Pool + Workspace          │  │
│  │  User-selected   │  │  ├─ Desktop and/or RemoteApp    │  │
│  │  host subnet     │  │  └─ Start VM on Connect         │  │
│  │  PE subnet       │  └─────────────────────────────────┘  │
│  └─────────────────┘  ┌─────────────────────────────────┐  │
│                        │  Session Host VMs                │  │
│                        │  ├─ Windows 11 Multi-Session     │  │
│  ┌─────────────────┐  │  ├─ Entra ID Joined              │  │
│  │  FSLogix Storage │  │  └─ AVD Agent (Custom Script)   │  │
│  │  (Azure Files)   │  └─────────────────────────────────┘  │
│  └─────────────────┘                                        │
│                        ┌─────────────────────────────────┐  │
│                        │  Monitoring                      │  │
│                        │  Log Analytics Workspace         │  │
│                        └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Features

- **Delivery Modes**: `PersonalDesktop`, `PooledRemoteApp`, and `PooledDesktopAndRemoteApp`, with legacy `hostPoolType` fallback for existing desktop-only deployments
- **Host Pool**: Pooled (BreadthFirst) or Personal, with Start VM on Connect
- **Session Hosts**: Windows 11 24H2 Multi-Session, Entra ID joined, System Assigned Managed Identity
- **FSLogix**: Azure Files share for user profile containers (Entra ID Kerberos auth, VNet-restricted)
- **Networking**: Uses an existing VNet and existing subnets selected at deployment time through the portal wizard
- **Monitoring**: Log Analytics workspace for diagnostics
- **Application Publishing**: Desktop app group, RemoteApp app group, or both from the same template
- **Access Assignment**: When `avdUserObjectId` is provided, the template assigns `Desktop Virtualization User` on the published app groups and `Virtual Machine User Login` on the resource group
- **Security**: TLS 1.2 enforced on storage, no shared key access, and a CSE-driven AVD agent install using a GitHub-hosted script to avoid Windows command-line length limits

## Prerequisites

- Azure subscription with **Owner** access (required for auto role assignments; Contributor is sufficient if `avdUserObjectId` is left empty)
- Resource provider `Microsoft.DesktopVirtualization` registered
- Resource provider `Microsoft.Storage` registered (for FSLogix)

## Quick Start

### Option 1: Deploy to Azure (Portal)

Click the **Deploy to Azure** button above for a guided deployment experience.

Important:

- the portal wizard now lists existing VNets and subnets from the selected subscription
- select the target VNet first, then choose the session host and private endpoint subnets from dropdowns
- `storageAccountName` is a required free-form field in the portal
- you must enter a globally unique name during deployment
- the template no longer provides a default storage account name
- `remoteApps` is only used when `avdMode` publishes RemoteApps

### Option 2: Azure CLI

```bash
# Create resource group
az group create --name rg-avd-avd1-dev --location westus2

# Deploy with a mode-specific sample file
az deployment group create \
  --resource-group rg-avd-avd1-dev \
  --template-file infra/main.bicep \
  --parameters @infra/samples/main.pooleddesktopandremoteapp.parameters.json \
  --parameters adminPassword='<secure-password>' \
               storageAccountName='<globally-unique-storage-name>' \
               avdUserObjectId='<entra-object-id>'
```

### Option 3: PowerShell

```powershell
# Create resource group
New-AzResourceGroup -Name "rg-avd-avd1-dev" -Location "westus2"

# Deploy with a mode-specific sample file
New-AzResourceGroupDeployment `
  -ResourceGroupName "rg-avd-avd1-dev" `
  -TemplateFile "infra/main.bicep" `
  -TemplateParameterFile "infra/samples/main.pooleddesktopandremoteapp.parameters.json" `
  -adminPassword (Read-Host -AsSecureString "Admin Password") `
  -storageAccountName "<globally-unique-storage-name>" `
  -avdUserObjectId "<entra-object-id>"
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

If `avdUserObjectId` is supplied, the template assigns end-user access automatically. If it is left empty, assign access after deployment.

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

- If `avdUserObjectId` was left empty, assign `Desktop Virtualization User` on the published application group and `Virtual Machine User Login` on the resource group before testing access
- **Web Client**: [https://client.wvd.microsoft.com](https://client.wvd.microsoft.com/arm/webclient/index.html)
- **Windows App / RD Client**: [Download](https://aka.ms/AVDClientDownload)

## Documentation

- `docs/Click2Deploy.md`: end-to-end Deploy-to-Azure portal flow and runtime behavior
- `docs/Deployment-Manual.md`: detailed deployment guide, architecture notes, and troubleshooting

## Related

- [Azure Virtual Desktop Documentation](https://learn.microsoft.com/azure/virtual-desktop/)
- [AVD Accelerator](https://github.com/Azure/avdaccelerator)
- [Cloud Adoption Framework](https://learn.microsoft.com/azure/cloud-adoption-framework/)

## License

MIT
