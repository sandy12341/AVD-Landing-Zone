# AVD Landing Zone — Deployment Manual

> **Version:** 1.0  
> **Last Updated:** March 24, 2026  
> **Repository:** `sandy12341/AVD-Landing-Zone`

---

## Table of Contents

1. [Pre-Requisites](#1-pre-requisites)
2. [Deployment Flow — End to End](#2-deployment-flow--end-to-end)
3. [Repository Structure & Role of Each File](#3-repository-structure--role-of-each-file)
4. [Architecture Deep Dive — Agents, Identity & Registration](#4-architecture-deep-dive--agents-identity--registration)
5. [Post-Deployment Configuration & Troubleshooting](#5-post-deployment-configuration--troubleshooting)

---

## 1. Pre-Requisites

### 1.1 Azure Subscription Requirements

| Requirement | Details |
|---|---|
| **Azure Subscription** | Active subscription with **Contributor** role (or higher) on the target resource group. |
| **Subscription ID** | Note your subscription ID — needed for CLI/PowerShell deployments. |
| **Region** | Choose a region that supports Azure Virtual Desktop (e.g., `westus2`, `eastus`, `westeurope`). |

### 1.2 Resource Provider Registration

The following resource providers **must** be registered on the subscription before deployment. If they are not registered, the deployment will fail.

```bash
az provider register --namespace Microsoft.DesktopVirtualization
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Storage         # Required for FSLogix
az provider register --namespace Microsoft.OperationalInsights  # Required for Monitoring
```

To verify registration status:

```bash
az provider show --namespace Microsoft.DesktopVirtualization --query "registrationState" -o tsv
```

### 1.3 Entra ID (Azure AD) Requirements

- **Entra ID Tenant**: The subscription must be linked to a Microsoft Entra ID tenant.
- **Entra ID Join**: Session hosts are Entra ID joined (not traditional AD-joined). No Active Directory Domain Controller or Azure AD DS is required.
- **User Accounts**: Users who will connect to AVD must exist in the same Entra ID tenant.

### 1.4 Permissions Summary

| Action | Required Role |
|---|---|
| Deploy the template | **Contributor** on the resource group |
| Assign "Desktop Virtualization User" (post-deploy) | **User Access Administrator** on the Application Group |
| Assign "Virtual Machine User Login" (post-deploy) | **User Access Administrator** on the Resource Group |

### 1.5 Tools (for CLI Deployment Only)

- **Azure CLI** v2.50+ with Bicep CLI, **or**
- **Azure PowerShell** Az module v10+
- A browser (for the "Deploy to Azure" button — no tooling required)

### 1.6 Networking / Firewall

Session host VMs require **outbound internet access** to:

| Endpoint | Purpose |
|---|---|
| `login.microsoftonline.com` | Entra ID authentication |
| `*.wvd.microsoft.com` | AVD control plane |
| `169.254.169.254` | Azure Instance Metadata Service (IMDS) — used for managed identity token retrieval |
| `management.azure.com` | ARM API — used by the VM to retrieve the host pool registration token |
| `query.prod.cms.rt.microsoft.com` | Microsoft download CDN — AVD BootLoader and RDAgent MSI downloads |

> **Note:** `raw.githubusercontent.com` is **no longer required** — the Install-AVDAgent.ps1 script is embedded inline in the ARM template at compile time.

> **Important:** If a firewall or NSG blocks outbound access to any of these endpoints, the agent installation will fail silently. The CSE (Custom Script Extension) will time out and the session host will not register.

---

## 2. Deployment Flow — End to End

### 2.1 Overview

The deployment is fully automated — a single ARM template deployment creates all resources, installs the AVD agent, and registers session hosts with the host pool. **No manual steps are required** after the template parameters are filled in.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         DEPLOYMENT TIMELINE                              │
│                                                                          │
│  T+0s     ARM deployment begins                                         │
│  T+10s    Networking module completes (VNet, Subnets, NSG)               │
│  T+20s    Host Pool + Application Group + Workspace created              │
│  T+30s    Session Host VMs begin provisioning                            │
│  T+60s    NICs created, VMs provisioning in parallel                     │
│  T+90s    Entra ID Join extension installs on each VM                    │
│  T+120s   Role assignment (Desktop Virtualization Contributor) applied   │
│  T+150s   Custom Script Extension begins (Install-AVDAgent.ps1)         │
│  T+180s   Script retrieves registration token via managed identity       │
│  T+210s   BootLoader + RDAgent MSIs installed                            │
│  T+240s   Agent registers with host pool (registry key loop)             │
│  T+300s   Session hosts show "Available" in host pool                    │
│  T+360s   Deployment completes (~6 minutes total)                        │
└──────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Option A: Deploy to Azure (One-Click Portal Deployment)

This is the recommended method. It requires **no tooling** — just a browser.

1. **Click the Deploy to Azure button** from the repo README or the MVP Catalog Portal:

   ```
   https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsandy12341%2FAVD-Landing-Zone%2Fmaster%2Finfra%2Fazuredeploy.json
   ```

2. **Fill in the required parameters** on the Azure Portal custom deployment form:

   | Parameter | Example Value | Notes |
   |---|---|---|
   | Resource Group | `rg-avd-myapp-dev` | Create new or use existing |
   | Region | `West US 2` | Must support AVD |
   | Deployment Prefix | `myapp` | Max 6 characters. Used in all resource names. |
   | Environment | `dev` | Options: `dev`, `test`, `prod` |
   | Session Host Count | `2` | Number of VMs (1–10) |
   | Vm Size | `Standard_D2ads_v5` | Any supported VM SKU |
   | Host Pool Type | `Pooled` | `Pooled` or `Personal` |
   | Admin Username | `avdadmin` | Local admin for VMs |
   | Admin Password | `(secure value)` | Must meet Azure complexity requirements |
   | Deploy FSLogix | `true` | Creates Azure Files storage for profiles |
   | Deploy Monitoring | `true` | Creates Log Analytics workspace |

3. **Click "Review + Create"**, then **"Create"**. The deployment takes approximately **5–7 minutes**.

4. **No further manual steps** — session hosts will self-register with the host pool.

### 2.3 Option B: Azure CLI Deployment

```bash
# 1. Create a resource group
az group create --name rg-avd-myapp-dev --location westus2

# 2. Deploy the template (from GitHub raw URL — same as portal)
az deployment group create \
  --resource-group rg-avd-myapp-dev \
  --template-uri "https://raw.githubusercontent.com/sandy12341/AVD-Landing-Zone/master/infra/azuredeploy.json" \
  --parameters deploymentPrefix='myapp' \
               environment='dev' \
               sessionHostCount=2 \
               vmSize='Standard_D2ads_v5' \
               hostPoolType='Pooled' \
               adminUsername='avdadmin' \
               adminPassword='YourSecurePassword123!'
```

### 2.4 Option C: Local Bicep Deployment (for Developers)

```bash
# Clone the repo
git clone https://github.com/sandy12341/AVD-Landing-Zone.git
cd AVD-Landing-Zone

# Deploy from local Bicep
az deployment group create \
  --resource-group rg-avd-myapp-dev \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json \
  --parameters adminPassword='YourSecurePassword123!'
```

### 2.5 Deployment Module Execution Order

ARM deploys the modules in the following dependency chain:

```
main.bicep (orchestrator)
  │
  ├──► network.bicep           (no dependencies)
  │      └── VNet, Subnets, NSG
  │
  ├──► hostpool.bicep           (no dependencies)
  │      └── Host Pool, App Group, Workspace
  │
  ├──► sessionhosts.bicep       (depends on: network, hostpool)
  │      ├── NICs
  │      ├── VMs (System Assigned Managed Identity)
  │      ├── Role Assignment (Desktop Virtualization Contributor → each VM)
  │      ├── Entra ID Join Extension (AADLoginForWindows)
  │      └── Custom Script Extension (Install-AVDAgent.ps1)
  │            ├── Retrieves registration token via IMDS + ARM API
  │            ├── Downloads + installs BootLoader MSI
  │            ├── Downloads + installs RDAgent MSI
  │            └── Writes token to registry + restarts services
  │
  ├──► fslogix.bicep            (conditional: deployFSLogix == true)
  │      └── Storage Account, File Share
  │
  └──► monitoring.bicep         (conditional: deployMonitoring == true)
         └── Log Analytics Workspace
```

> **Key dependency**: The Custom Script Extension (`InstallAVDAgent`) has an explicit `dependsOn` on both the Entra ID Join extension and the Role Assignment. This ensures the VM has its managed identity role active before it attempts to retrieve the registration token.

---

## 3. Repository Structure & Role of Each File

```
AVD-Landing-Zone/
├── README.md                          # Repo overview, architecture diagram, quick start
├── .gitignore                         # Git ignore rules
├── docs/
│   └── Deployment-Manual.md           # This document
└── infra/
    ├── main.bicep                     # Main orchestrator — entry point for all deployments
    ├── main.parameters.json           # Default parameter values for CLI/PowerShell deployments
    ├── azuredeploy.json               # Pre-compiled ARM JSON template (used by "Deploy to Azure" button)
    ├── modules/
    │   ├── network.bicep              # Virtual Network, Subnets, NSG
    │   ├── hostpool.bicep             # Host Pool, Application Group, Workspace
    │   ├── sessionhosts.bicep         # VMs, NICs, Entra ID Join, AVD Agent, Role Assignments
    │   ├── fslogix.bicep              # Azure Files storage for user profiles
    │   └── monitoring.bicep           # Log Analytics workspace
    └── scripts/
        └── Install-AVDAgent.ps1       # PowerShell script that runs inside each VM via CSE
```

### 3.1 `infra/main.bicep` — Main Orchestrator

**Purpose:** The single entry point for the entire deployment. All other modules are invoked from here.

**Responsibilities:**
- Defines all user-facing parameters (prefix, environment, VM count, size, etc.)
- Constructs the `namingPrefix` variable: `{deploymentPrefix}-{environment}` (e.g., `myapp-dev`)
- Applies consistent tags (`Environment`, `Project`, `DeployedBy`) to all resources
- Invokes the 5 child modules with computed names and passes parameters
- Conditionally deploys FSLogix and Monitoring based on boolean flags
- Outputs key resource identifiers (host pool name, VNet ID, VM names, etc.)

**Naming Convention:** All resources follow this pattern:
| Resource | Name Format | Example |
|---|---|---|
| VNet | `vnet-avd-{prefix}-{env}` | `vnet-avd-myapp-dev` |
| Host Pool | `hp-avd-{prefix}-{env}` | `hp-avd-myapp-dev` |
| Workspace | `ws-avd-{prefix}-{env}` | `ws-avd-myapp-dev` |
| App Group | `dag-avd-{prefix}-{env}` | `dag-avd-myapp-dev` |
| VMs | `vm-avd-{prefix}-{env}-{i}` | `vm-avd-myapp-dev-0` |
| Storage | `stavd{prefix}{env}` (no hyphens) | `stavdmyappdev` |
| Log Analytics | `log-avd-{prefix}-{env}` | `log-avd-myapp-dev` |

### 3.2 `infra/main.parameters.json` — Default Parameters

**Purpose:** Provides default parameter values for CLI/PowerShell deployments. Not used by the portal "Deploy to Azure" button (which generates its own form from the ARM template schema).

**Key Defaults:**
- `deploymentPrefix`: `avd1`
- `environment`: `dev`
- `sessionHostCount`: `1`
- `vmSize`: `Standard_D2ads_v5`
- `adminPassword`: **Not included** — must be supplied at deploy time for security

### 3.3 `infra/azuredeploy.json` — Compiled ARM Template

**Purpose:** A pre-compiled JSON version of `main.bicep` + all nested modules. This is the file that the **"Deploy to Azure" button** points to.

**How it's generated:**

```bash
az bicep build --file infra/main.bicep --outfile infra/azuredeploy.json
```

> **Critical:** Whenever you modify any `.bicep` file, you **must** rebuild `azuredeploy.json` and commit it. The portal deployment button always pulls this JSON file from the `master` branch on GitHub. If it's stale, portal deployments will use outdated templates.

### 3.4 `infra/modules/network.bicep` — Networking

**Purpose:** Creates the isolated network foundation for the AVD environment.

**Resources Created:**

| Resource | Name | Details |
|---|---|---|
| Virtual Network | `vnet-avd-{prefix}-{env}` | Address space: `10.20.0.0/16` (configurable) |
| Subnet — Session Hosts | `snet-avd-sessionhosts` | `10.20.1.0/24` — where VMs are deployed |
| Subnet — Private Endpoints | `snet-avd-privateendpoints` | `10.20.2.0/24` — reserved for PE connectivity |
| NSG | `nsg-avd-sessionhosts` | Attached to the session hosts subnet |

**NSG Rules:**

| Rule | Priority | Direction | Action | Protocol | Source | Destination Port |
|---|---|---|---|---|---|---|
| AllowRDP | 1000 | Inbound | Allow | TCP | VirtualNetwork | 3389 |
| DenyAllInbound | 4096 | Inbound | Deny | * | * | * |

> **Security Note:** RDP is only allowed from within the VNet. There is no public IP or inbound internet access to the session hosts. Users connect through the AVD control plane (reverse-connect transport), which requires no inbound ports.

**Outputs:** `vnetId`, `sessionHostSubnetId`, `privateEndpointSubnetId`

### 3.5 `infra/modules/hostpool.bicep` — Host Pool, App Group & Workspace

**Purpose:** Creates the AVD control plane resources — the logical container for session hosts and the workspace that users see when they connect.

**Resources Created:**

| Resource | Type | Details |
|---|---|---|
| **Host Pool** | `Microsoft.DesktopVirtualization/hostPools` | Load balancer: BreadthFirst. Max sessions: 10. Start VM on Connect: enabled. |
| **Application Group** | `Microsoft.DesktopVirtualization/applicationGroups` | Type: Desktop (full desktop experience). Linked to the host pool. |
| **Workspace** | `Microsoft.DesktopVirtualization/workspaces` | References the Application Group. This is what users see in the Windows App / Web Client. |

**Key Configuration Details:**

- **Custom RDP Properties** (baked into the host pool):
  ```
  targetisaadjoined:i:1          → Tells the client this is an Entra ID joined host
  enablerdsaadauth:i:1           → Enables Entra ID SSO (no password prompt after sign-in)
  redirectclipboard:i:1          → Clipboard redirection enabled
  audiomode:i:0                  → Audio playback on local computer
  videoplaybackmode:i:1          → Optimized video playback
  use multimon:i:1               → Multi-monitor support
  enablecredsspsupport:i:1       → CredSSP for SSO
  redirectwebauthn:i:1           → WebAuthn/FIDO2 passkey redirection
  ```

- **Registration Token:** The host pool is configured with `registrationTokenOperation: 'Update'` and an expiration time of **48 hours** from deployment time. This token is **not** output from the template — instead, session host VMs retrieve it dynamically at deployment time using their managed identity (see Section 4).

**Outputs:** `hostPoolId`, `hostPoolName`, `appGroupId`, `workspaceId`

### 3.6 `infra/modules/sessionhosts.bicep` — Session Host VMs

**Purpose:** The most complex module. Deploys the Windows 11 VMs, joins them to Entra ID, assigns RBAC roles, and runs the AVD agent installation script.

**Resources Created (per VM):**

| Resource | Type | Details |
|---|---|---|
| **NIC** | `Microsoft.Network/networkInterfaces` | Dynamic private IP in the session hosts subnet. Delete option: Delete (cleaned up with VM). |
| **VM** | `Microsoft.Compute/virtualMachines` | Windows 11 24H2 Multi-Session. System Assigned Managed Identity enabled. Premium SSD OS disk. License: `Windows_Client` (for Azure Hybrid Benefit). |
| **Role Assignment** | `Microsoft.Authorization/roleAssignments` | Assigns **Desktop Virtualization Contributor** (`082f0a83-3be5-4ba1-904c-961cca79b387`) to the VM's managed identity, scoped to the host pool. This allows the VM to call the `retrieveRegistrationToken` API. |
| **Entra ID Join Extension** | `AADLoginForWindows` | Joins the VM to Entra ID. Version 2.2 with auto-upgrade. |
| **Custom Script Extension** | `InstallAVDAgent` | Downloads and executes `Install-AVDAgent.ps1` from GitHub. Passes the host pool resource ID as a parameter. |

**Computer Name Logic:**
- ARM imposes a 15-character limit on Windows computer names.
- The `shortPrefix` variable strips `vm-` and hyphens from `vmNamePrefix`, then takes the first 12 characters.
- Final computer name: `{shortPrefix}{index}` (e.g., `avdmyappdev0`).
- This prevents hostname collision errors when deploying multiple environments.

**Extension Dependency Chain:**
```
VM Created
  └──► Entra ID Join (AADLoginForWindows)
         └──► Role Assignment (Desktop Virtualization Contributor)
                └──► Custom Script Extension (Install-AVDAgent.ps1)
```

> The CSE **will not run** until both the Entra ID join and the role assignment are complete. This is enforced via `dependsOn` in the Bicep template.

**Outputs:** `vmNames`, `vmIds`

### 3.7 `infra/modules/fslogix.bicep` — FSLogix Profile Storage

**Purpose:** Creates an Azure Storage Account with an SMB file share for FSLogix user profile containers. When users log in to AVD, their profile (desktop, documents, app settings) is loaded from this file share.

**Resources Created:**

| Resource | Details |
|---|---|
| **Storage Account** | StorageV2, Standard_LRS. TLS 1.2 enforced. Public blob access disabled. |
| **File Service** | Default file service on the storage account. |
| **File Share** | Name: `fslogix-profiles`. Quota: 100 GiB. Protocol: SMB. |

> **Note:** This module is conditionally deployed (`deployFSLogix` parameter, default `true`). Additional GPO/Intune configuration is needed to point session hosts to this share (not part of the automated deployment).

**Outputs:** `storageAccountId`, `storageAccountName`, `fileShareName`

### 3.8 `infra/modules/monitoring.bicep` — Log Analytics

**Purpose:** Creates a Log Analytics workspace for centralized diagnostics and monitoring.

**Resources Created:**

| Resource | Details |
|---|---|
| **Log Analytics Workspace** | SKU: PerGB2018. Retention: 30 days. |

> **Note:** Conditionally deployed via the `deployMonitoring` parameter (default `true`). To enable AVD Insights, you would additionally configure diagnostic settings on the host pool and VMs to send logs to this workspace (not part of the automated deployment).

**Outputs:** `workspaceId`, `workspaceName`

### 3.9 `infra/scripts/Install-AVDAgent.ps1` — Agent Installation Script

**Purpose:** This PowerShell script runs inside each session host VM via the Custom Script Extension. It is the **critical automation** that eliminates any manual post-deployment steps.

**Execution context:** Runs as `SYSTEM` on the VM, with outbound internet access.

**Input parameter:** `-HostPoolResourceId` — the full ARM resource ID of the host pool (e.g., `/subscriptions/.../hostPools/hp-avd-myapp-dev`).

**Step-by-step behavior:**

```
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 1: Retrieve Registration Token (via Managed Identity)             │
│                                                                         │
│  1. Call IMDS endpoint (169.254.169.254) to get an access token         │
│     for the VM's system-assigned managed identity                       │
│     Target audience: https://management.azure.com/                      │
│                                                                         │
│  2. POST to ARM API:                                                    │
│     https://management.azure.com{HostPoolResourceId}/                   │
│         retrieveRegistrationToken?api-version=2024-04-08-preview        │
│     Authorization: Bearer {access_token}                                │
│                                                                         │
│  3. Extract the token from the response                                 │
│                                                                         │
│  Retry: Up to 18 attempts, 10 seconds apart (total ~3 minutes)         │
│  Why retries? The role assignment may take 1-2 minutes to propagate.    │
└─────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 2: Install AVD BootLoader                                         │
│                                                                         │
│  Download URL: https://query.prod.cms.rt.microsoft.com/.../RWrxrH       │
│  Install: msiexec /i BootLoader.msi /quiet /norestart                   │
│                                                                         │
│  The BootLoader is a Windows service (RDAgentBootLoader) that manages   │
│  the lifecycle of the RD Agent — monitors health, restarts it, and      │
│  handles updates.                                                       │
└─────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 3: Install AVD RD Agent                                           │
│                                                                         │
│  Download URL: https://query.prod.cms.rt.microsoft.com/.../RWrmXv       │
│  Install: msiexec /i RDAgent.msi /quiet /norestart                      │
│                                                                         │
│  The RD Agent (RdAgent) is the core AVD service that:                   │
│  - Maintains a persistent connection to the AVD control plane           │
│  - Sends heartbeats to report session host health                       │
│  - Brokers user sessions to this VM                                     │
│  - Reports capacity (available sessions) back to the host pool          │
└─────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  STEP 4: Register with Host Pool (Registry-Based)                       │
│                                                                         │
│  1. Stop both services: RDAgentBootLoader, RdAgent                      │
│  2. Write to registry:                                                  │
│     HKLM:\SOFTWARE\Microsoft\RDInfraAgent                               │
│       RegistrationToken = {token from Step 1}                           │
│       IsRegistered = 0                                                  │
│  3. Start RdAgent, then RDAgentBootLoader                               │
│  4. Poll IsRegistered every 10 seconds for up to 90 seconds             │
│  5. If not registered after 90s, restart services and retry             │
│                                                                         │
│  Total: 3 retry attempts × 90 seconds each = up to 4.5 minutes         │
│                                                                         │
│  When IsRegistered flips to 1, the session host appears as              │
│  "Available" in the Azure Portal host pool blade.                       │
└─────────────────────────────────────────────────────────────────────────┘
```

**Registry keys used by the AVD Agent:**

| Registry Path | Key | Value | Purpose |
|---|---|---|---|
| `HKLM:\SOFTWARE\Microsoft\RDInfraAgent` | `RegistrationToken` | JWT string | The host pool registration token |
| `HKLM:\SOFTWARE\Microsoft\RDInfraAgent` | `IsRegistered` | `0` or `1` | Set to `0` before registration; agent sets to `1` upon success |

**Windows Services installed:**

| Service Name | Display Name | Purpose |
|---|---|---|
| `RdAgent` | Remote Desktop Agent | Core AVD agent — heartbeat, session brokering, health reporting |
| `RDAgentBootLoader` | Remote Desktop Agent Boot Loader | Manages RdAgent lifecycle — restarts, updates, monitoring |

---

## 4. Architecture Deep Dive — Agents, Identity & Registration

### 4.1 Why Managed Identity Self-Registration?

Traditional AVD deployments require a **two-step process:**
1. Deploy the host pool → manually copy the registration token
2. Pass the token to session hosts during VM deployment

This breaks one-click deployment because ARM cannot output the registration token as a template output — the `registrationInfo.token` property is only accessible via a POST action (`retrieveRegistrationToken`), not a GET.

**Solution:** Each VM uses its **System Assigned Managed Identity** to call the ARM API and retrieve the token itself, at deployment time, from inside the VM.

### 4.2 Identity & RBAC Flow

```
┌──────────────────┐         ┌──────────────────────────────────┐
│  Session Host VM  │         │  Host Pool                        │
│                   │         │  hp-avd-{prefix}-{env}            │
│  Identity:        │         │                                    │
│  System Assigned  │────────►│  Role: Desktop Virtualization      │
│  Managed Identity │  has    │        Contributor                 │
│                   │  role   │  (082f0a83-3be5-4ba1-...)          │
└──────────────────┘         └──────────────────────────────────┘
         │
         │ 1. Requests access token from IMDS
         ▼
┌──────────────────┐
│  IMDS             │
│  169.254.169.254  │
│                   │
│  Returns token    │
│  for management   │
│  .azure.com       │
└──────────────────┘
         │
         │ 2. Calls ARM API with Bearer token
         ▼
┌──────────────────────────────────────────┐
│  ARM API                                  │
│  POST /hostPools/{name}/                  │
│       retrieveRegistrationToken           │
│                                           │
│  Returns: { "token": "eyJ..." }           │
└──────────────────────────────────────────┘
         │
         │ 3. Writes token to registry
         ▼
┌──────────────────────────────────────────┐
│  HKLM:\SOFTWARE\Microsoft\RDInfraAgent    │
│  RegistrationToken = eyJ...               │
│  IsRegistered = 0 → 1                     │
└──────────────────────────────────────────┘
         │
         │ 4. Agent connects to AVD control plane
         ▼
┌──────────────────────────────────────────┐
│  AVD Control Plane (*.wvd.microsoft.com)  │
│  Session host status: Available           │
│  Heartbeat: active                        │
└──────────────────────────────────────────┘
```

### 4.3 Role Assignment Details

| Role | Role Definition ID | Scope | Assigned To | Purpose |
|---|---|---|---|---|
| **Desktop Virtualization Contributor** | `082f0a83-3be5-4ba1-904c-961cca79b387` | Host Pool resource | Each VM's system-assigned managed identity | Allows the VM to call `retrieveRegistrationToken` on the host pool |

> This role is automatically assigned during deployment via `sessionhosts.bicep`. No manual RBAC configuration is needed.

### 4.4 Entra ID Join

Each session host VM has the `AADLoginForWindows` extension (version 2.2) which:
- Registers the VM as a device in Entra ID
- Enables Entra ID-based RDP authentication (SSO)
- Creates a device object in the Entra ID directory (visible under **Devices** in the Entra portal)

> **Cleanup note:** When you delete the resource group, the **Entra ID device objects are NOT automatically deleted**. You must manually remove them from the Entra ID portal or via the Graph API to avoid stale device records.

### 4.5 Resource Summary — What Gets Deployed

For a deployment with `deploymentPrefix=myapp`, `environment=dev`, `sessionHostCount=2`:

| # | Resource | Type | Purpose |
|---|---|---|---|
| 1 | `vnet-avd-myapp-dev` | Virtual Network | Network isolation |
| 2 | `nsg-avd-sessionhosts` | Network Security Group | Firewall rules |
| 3 | `hp-avd-myapp-dev` | Host Pool | AVD session host container |
| 4 | `dag-avd-myapp-dev` | Application Group | Desktop app group |
| 5 | `ws-avd-myapp-dev` | Workspace | User-facing workspace |
| 6 | `nic-vm-avd-myapp-dev-0` | NIC | VM 0 network interface |
| 7 | `vm-avd-myapp-dev-0` | Virtual Machine | Session host 0 |
| 8 | `nic-vm-avd-myapp-dev-1` | NIC | VM 1 network interface |
| 9 | `vm-avd-myapp-dev-1` | Virtual Machine | Session host 1 |
| 10 | `stavdmyappdev` | Storage Account | FSLogix profiles |
| 11 | `log-avd-myapp-dev` | Log Analytics Workspace | Monitoring |

Plus per-VM: OS Disk (managed), Entra ID device registration, RBAC role assignment.

---

## 5. Post-Deployment Configuration & Troubleshooting

### 5.1 Required Post-Deployment Steps

After the template deployment succeeds, you need to assign **two RBAC roles** to allow users to connect:

#### A. Desktop Virtualization User (on the Application Group)

Grants the user permission to see and launch the desktop in the AVD client.

```bash
az role assignment create \
  --assignee "user@yourdomain.com" \
  --role "Desktop Virtualization User" \
  --scope "/subscriptions/{sub-id}/resourceGroups/{rg-name}/providers/Microsoft.DesktopVirtualization/applicationGroups/dag-avd-{prefix}-{env}"
```

#### B. Virtual Machine User Login (on the Resource Group)

Grants the user permission to RDP into the Entra ID-joined VMs.

```bash
az role assignment create \
  --assignee "user@yourdomain.com" \
  --role "Virtual Machine User Login" \
  --scope "/subscriptions/{sub-id}/resourceGroups/{rg-name}"
```

> **For admin access**, use the `Virtual Machine Administrator Login` role instead.

### 5.2 Connecting to AVD

After role assignment, users can connect via:

| Client | URL |
|---|---|
| **Web Client** | https://client.wvd.microsoft.com/arm/webclient/index.html |
| **Windows App** | https://aka.ms/AVDClientDownload |
| **macOS / iOS / Android** | Microsoft Remote Desktop app from respective app stores |

### 5.3 Verifying Session Host Registration

```bash
# Check session host status
az desktopvirtualization session-host list \
  --host-pool-name hp-avd-{prefix}-{env} \
  --resource-group {rg-name} \
  --query "[].{Name:name, Status:status, Agent:agentVersion, Heartbeat:lastHeartBeat}" \
  -o table
```

Expected output:
```
Name                             Status     Agent            Heartbeat
-------------------------------  ---------  ---------------  -------------------------
hp-avd-myapp-dev/avdmyappdev0   Available  1.0.13229.200    2026-03-24T12:00:00.000Z
hp-avd-myapp-dev/avdmyappdev1   Available  1.0.13229.200    2026-03-24T12:00:00.000Z
```

### 5.4 Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| Session host shows **Unavailable** | Agent failed to register | Check CSE status: Portal → VM → Extensions → InstallAVDAgent → View detailed status |
| CSE failed with **URI parsing error** | Quoting issue in the CSE command | Ensure `HostPoolResourceId` is passed with double quotes, not single quotes |
| CSE failed with **Access denied** | Role assignment hasn't propagated yet | The script retries 18 times (3 min). If still failing, manually rerun the CSE |
| CSE timed out | Outbound internet blocked | Check NSG/firewall allows HTTPS to `management.azure.com`, `169.254.169.254`, and CDN |
| Entra ID device not cleaned up after RG deletion | Expected behavior — Entra ID devices persist | Delete manually: Entra Portal → Devices, or `az rest --method DELETE --url "https://graph.microsoft.com/v1.0/devices/{device-id}"` |
| User can't see desktop in AVD client | Missing role assignment | Assign `Desktop Virtualization User` on the Application Group |
| User sees desktop but gets **access denied** on connect | Missing VM login role | Assign `Virtual Machine User Login` on the Resource Group |
| Registration token expired | Token is valid for 48 hours from deployment time | Rerun the CSE or redeploy session hosts |

### 5.5 Updating the Template

When modifying any Bicep file:

1. Edit the `.bicep` file(s)
2. Rebuild the ARM template:
   ```bash
   az bicep build --file infra/main.bicep --outfile infra/azuredeploy.json
   ```
3. Commit and push both the `.bicep` and `azuredeploy.json` files
4. The "Deploy to Azure" button will immediately use the updated template (pulled from GitHub `master` branch)

### 5.6 Destroying Resources

To completely clean up an AVD deployment:

```bash
# 1. Delete the resource group (deletes all Azure resources)
az group delete --name rg-avd-{prefix}-{env} --yes --no-wait

# 2. Delete stale Entra ID device objects
$devices = az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/devices?\$filter=startswith(displayName,'avd{prefix}')" \
  --query "value[].id" -o tsv

foreach ($deviceId in $devices) {
    az rest --method DELETE --url "https://graph.microsoft.com/v1.0/devices/$deviceId"
}
```

---

*End of Deployment Manual*
