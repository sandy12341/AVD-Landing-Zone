# Azure Virtual Desktop + Landing Zone

Production-ready Azure Virtual Desktop deployment with Landing Zone architecture. Includes validated `PersonalDesktop`, `PooledRemoteApp`, and `PooledDesktopAndRemoteApp` delivery modes, FSLogix profile containers, Entra ID join, network segmentation, and monitoring.

## Deploy to Azure

### One-Click Deployment with VNet/Subnet Dropdowns ⭐

Click the button below for a guided deployment with dynamic VNet and subnet selection:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsandy12341%2FAVD-Landing-Zone%2F7d5533b%2Finfra%2Fmanagedapp%2Fdist%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fsandy12341%2FAVD-Landing-Zone%2F7d5533b%2Finfra%2Fmanagedapp%2FcreateUiDefinition.json)

**Pinned to commit `7d5533b`.**
**What You Get:**
- Multi-step portal wizard (5 steps)
- **VNet selection dropdown** — lists all VNets in subscription
- **Subnet selection dropdown** — filtered by selected VNet  
- Configure host pool, session hosts, FSLogix, monitoring
- Auto-deploy to your subscription, your resources

**Deployment Flow:**
1. Click Deploy to Azure button
2. Portal opens with 5-step wizard
3. Select subscription and resource group
4. Basics: Host pool name, instance count, VM size
5. Networking: Select VNet and subnets from dropdowns
6. AVD Config: Delivery mode (Desktop/RemoteApp/Both)  
7. Storage & Monitoring: FSLogix and Log Analytics options
8. Access: (Optional) User object ID for RBAC assignment
9. Review and create

**Managed App Details:**
- **Subscription:** `830ef649-535d-4642-9436-356f9619c2e4`
- **Resource Group:** `rg-avd-managedapp-def`
- **Definition Name:** `avd-existing-network`
- **Location:** westus3

---

## Alternative Deployment Methods

### CLI Deployment with VNet/Subnet Dropdowns

You can also deploy using Azure CLI with the same VNet/subnet dropdown experience:
```bash
# Define parameters
DEFINITION_ID="/subscriptions/830ef649-535d-4642-9436-356f9619c2e4/resourceGroups/rg-avd-managedapp-def/providers/Microsoft.Solutions/applicationDefinitions/avd-existing-network"
SUBSCRIPTION_ID="your-subscription-id"
RESOURCE_GROUP="your-resource-group"

# Create resource group
az group create -n $RESOURCE_GROUP -l westus3

# Deploy the managed application
az deployment group create \
  -g $RESOURCE_GROUP \
  --subscription $SUBSCRIPTION_ID \
  -n "avd-app-deploy" \
  --template-spec "$DEFINITION_ID" \
  --parameters \
    hostPoolName="avd-hostpool" \
    instanceCount=2 \
    vmSize="Standard_D2s_v3" \
    deliveryMode="PooledDesktopAndRemoteApp" \
    existingVnetName="your-vnet" \
    existingVnetResourceGroupName="your-vnet-rg"
```

Or deploy via PowerShell:
```powershell
$definitionId = "/subscriptions/830ef649-535d-4642-9436-356f9619c2e4/resourceGroups/rg-avd-managedapp-def/providers/Microsoft.Solutions/applicationDefinitions/avd-existing-network"

az deployment group create `
  -g "your-resource-group" `
  --subscription "your-subscription-id" `
  -n "avd-app-deploy" `
  --template-spec "$definitionId"
```

**Benefits:**
- Multi-tenant self-service deployment
- Portal wizard with VNet and subnet dropdowns (no manual parameter entry)
- Each user deploys to their own subscription/resources
- Managed identity with automatic RBAC for resource access
- Shared definition = no duplication across organizations

### Option 2: ARM Template Deployment

Deploy directly from GitHub ARM template with portal form:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsandy12341%2FAVD-Landing-Zone%2Fmaster%2Finfra%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fsandy12341%2FAVD-Landing-Zone%2Fmaster%2Finfra%2FcreateUiDefinition.json)

**Note:** Requires parameter form entry; portal UI varies by template version.

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
cd infra/managedapp/dist
zip -r app.zip mainTemplate.json createUiDefinition.json
cd ../../..

# 4. Upload app.zip to your blob storage or GitHub release
# 5. Deploy managedApplicationDefinition to shared subscription
PACKAGE_URI="https://your-storage-account.blob.core.windows.net/container/app.zip"
PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv)"

az group create -n rg-avd-managedapp-def -l westus3

az deployment group create \
  -g rg-avd-managedapp-def \
  --template-file infra/managedapp/deployDefinition.bicep \
  --parameters \
    managedApplicationDefinitionName='avd-existing-network' \
    definitionDisplayName='Azure Virtual Desktop + ALZ' \
    packageFileUri="$PACKAGE_URI" \
    principalId="$PRINCIPAL_ID"
```

### Deploying a Managed Application Instance

Once the managed application definition is published, users can deploy instances:

**Using Azure CLI:**
```bash
# Get the definition resource ID (from shared subscription)
DEFINITION_ID="/subscriptions/{definition-subscription}/resourceGroups/rg-avd-managedapp-def/providers/Microsoft.Solutions/applicationDefinitions/avd-existing-network"

# Deploy to your subscription
az group create -n rg-avd-prod -l westus3

az deployment group create \
  -g rg-avd-prod \
  -n "avd-deployment" \
  --template-spec "$DEFINITION_ID" \
  --parameters \
    hostPoolName="avd-hostpool" \
    instanceCount=3 \
    vmSize="Standard_D2s_v3" \
    deliveryMode="PooledDesktopAndRemoteApp" \
    adminUsername="azureuser" \
    adminPassword="<SecurePassword>" \
    existingVnetName="my-vnet" \
    existingVnetResourceGroupName="my-vnet-rg" \
    sessionHostSubnetName="avd-subnet" \
    privateEndpointSubnetName="pe-subnet"
```

**Using PowerShell:**
```powershell
$definitionId = "/subscriptions/{definition-subscription}/resourceGroups/rg-avd-managedapp-def/providers/Microsoft.Solutions/applicationDefinitions/avd-existing-network"

az group create -n rg-avd-prod -l westus3

az deployment group create `
  -g rg-avd-prod `
  -n "avd-deployment" `
  --template-spec "$definitionId" `
  --parameters `
    hostPoolName="avd-hostpool" `
    instanceCount=3 `
    vmSize="Standard_D2s_v3" `
    deliveryMode="PooledDesktopAndRemoteApp" `
    adminUsername="azureuser" `
    adminPassword="<SecurePassword>" `
    existingVnetName="my-vnet" `
    existingVnetResourceGroupName="my-vnet-rg" `
    sessionHostSubnetName="avd-subnet" `
    privateEndpointSubnetName="pe-subnet"
```

### Multi-Tenant Deployment

To enable users in other Azure AD tenants to deploy from a shared published definition:

1. **Publish definition in shared subscription** (steps above)
2. **Share the definition resource ID** with other organizations:
   ```
   /subscriptions/{definition-subscription}/resourceGroups/rg-avd-managedapp-def/providers/Microsoft.Solutions/applicationDefinitions/avd-existing-network
   ```
3. **Users authenticate** with their own Azure credentials
4. **Each user deploys** to their own subscription with their own resources
5. **Managed app resources** (Host Pool, Session Hosts, FSLogix storage) remain in user's subscription and are owned by them

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
