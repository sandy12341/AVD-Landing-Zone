# Click2Deploy: End-to-End Flow When a User Clicks "Deploy to Azure"

This document explains the current end-to-end deployment flow for this Azure Virtual Desktop landing zone when a user clicks the **Deploy to Azure** button.

It reflects the current compiled ARM template in `infra/azuredeploy.json` and the latest validated deployment behavior.

---

## 1. What the button does

The **Deploy to Azure** button opens the Azure portal custom deployment experience by pointing the portal at the compiled ARM template stored in GitHub.

When the user clicks it:

1. The browser opens the Azure portal custom deployment blade.
2. The portal downloads `infra/azuredeploy.json` from GitHub.
3. The portal reads the template schema and parameters.
4. The portal generates the deployment form.
5. The user fills in values, selects or creates a resource group, and submits the deployment.

Important:

- The portal deploys the JSON template, not the Bicep source files directly.
- If `infra/azuredeploy.json` is not rebuilt after Bicep changes, the portal deploys stale logic.

---

## 2. What the user enters in the portal

The portal form is generated from the template parameters.

### Required inputs

- Subscription
- Resource group
- Region
- `adminUsername`
- `adminPassword`
- `storageAccountName` when `deployFSLogix` is `true`

### Common optional inputs

- `deploymentPrefix`
- `environment`
- `sessionHostCount`
- `vmSize`
- `avdMode`
- `hostPoolType` when using the legacy desktop-only fallback
- `deployFSLogix`
- `deployMonitoring`
- `remoteApps`
- `vnetAddressPrefix`
- `sessionHostSubnetPrefix`
- `privateEndpointSubnetPrefix`
- `avdUserObjectId`

### Validation rules enforced by the template

- `deploymentPrefix`: maximum 6 characters
- `sessionHostCount`: 1 to 10
- `avdMode`: `PersonalDesktop`, `PooledRemoteApp`, or `PooledDesktopAndRemoteApp`
- `hostPoolType`: `Pooled` or `Personal` when `avdMode` is empty
- `storageAccountName`: 3 to 24 characters, globally unique, lowercase letters and numbers only
- `adminPassword`: must satisfy Azure password complexity rules

Portal behavior:

- the Deploy to Azure form does not prefill `storageAccountName`
- the user must type a unique storage account name as part of the deployment
- this avoids collisions caused by reusing the old default value

When the user clicks **Review + create**, Azure Resource Manager performs preflight validation. When the user clicks **Create**, the deployment starts.

---

## 3. How ARM orchestrates the deployment

Azure Resource Manager receives the top-level template and builds a dependency graph.

The top-level deployment orchestrates these major components:

1. Network
2. Host pool, application groups, published RemoteApps, and workspace
3. Session hosts
4. FSLogix storage, if enabled
5. Monitoring, if enabled
6. Optional role assignments for the target AVD user

Execution behavior:

- `network`, `hostPool`, and `monitoring` can start independently
- `fslogix` waits for `network`, because it needs the session host subnet ID
- `sessionHosts` waits for both `network` and `hostPool`
- User role assignments run only if `avdUserObjectId` is provided

---

## 4. Phase 1: Network deployment

Deployment name: `deploy-network`

Azure creates:

- Network security group: `nsg-avd-sessionhosts`
- Public IP for NAT gateway: `vnet-avd-<prefix>-<env>-natgw-pip`
- NAT gateway: `vnet-avd-<prefix>-<env>-natgw`
- Virtual network: `vnet-avd-<prefix>-<env>`

Inside the VNet it creates:

- `snet-avd-sessionhosts`
- `snet-avd-privateendpoints`

Key behaviors:

- Session hosts do not get public IPs
- Outbound internet is provided through the NAT gateway
- The session host subnet includes a `Microsoft.Storage` service endpoint
- The NSG allows RDP only from within the virtual network, then denies all other inbound traffic

Why this matters:

- The VM can reach Microsoft endpoints for Entra join, AVD registration, ARM token retrieval, and MSI downloads
- The VM remains non-public from the internet

---

## 5. Phase 2: Host pool, application group, and workspace

Deployment name: `deploy-hostpool`

Azure creates:

- Host pool: `hp-avd-<prefix>-<env>`
- Desktop application group: `dag-avd-<prefix>-<env>` when the selected mode publishes desktops
- RemoteApp application group: `rag-avd-<prefix>-<env>` when the selected mode publishes RemoteApps
- Workspace: `ws-avd-<prefix>-<env>`

Host pool configuration includes:

- `Pooled` or `Personal`, derived from `avdMode` when it is provided and otherwise from the legacy `hostPoolType`
- `BreadthFirst` load balancing by default
- `startVMOnConnect: true`
- `Desktop` or `RailApplications` preferred app group type, based on what the selected mode publishes
- A 48-hour registration token generated via `registrationInfo`

If `avdMode` includes RemoteApps, the template also publishes one `Microsoft.DesktopVirtualization/applicationGroups/applications` resource for each object in `remoteApps`.

The host pool also sets custom RDP properties for Entra-joined AVD access, including:

- Entra-authenticated sessions
- multi-monitor support
- clipboard redirection
- WebAuthn redirection
- CredSSP support

---

## 6. Phase 3: Optional FSLogix storage

Deployment name: `deploy-fslogix`

This runs only when `deployFSLogix` is `true`.

Azure creates:

- Storage account
- File service
- Azure Files share named `fslogix-profiles`

Security and compliance settings applied automatically:

- `allowSharedKeyAccess: false`
- `minimumTlsVersion: TLS1_2`
- `allowBlobPublicAccess: false`
- `azureFilesIdentityBasedAuthentication.directoryServiceOptions: AADKERB`
- network ACL default action `Deny`
- VNet rule allowing only the session host subnet

Why this matters:

- The storage account is locked down by default
- Azure Files is prepared for Entra Kerberos-based authentication
- Session hosts can reach the share through the permitted subnet path

---

## 7. Phase 4: Optional monitoring

Deployment name: `deploy-monitoring`

This runs only when `deployMonitoring` is `true`.

Azure creates:

- Log Analytics workspace: `log-avd-<prefix>-<env>`

This gives the landing zone a monitoring workspace, although not every diagnostic setting is wired automatically by this template.

---

## 8. Phase 5: Session host deployment

Deployment name: `deploy-sessionhosts`

This is the longest and most important phase.

For each requested session host, Azure creates:

1. A network interface
2. A Windows 11 multi-session VM
3. A system-assigned managed identity on the VM
4. A role assignment for the VM identity on the host pool
5. The `AADLoginForWindows` extension
6. The `InstallAVDAgent` Custom Script Extension

### VM creation details

Each session host VM uses:

- Windows 11 24H2 multi-session image
- Premium SSD OS disk
- system-assigned managed identity
- no public IP
- session host subnet NIC placement
- local admin account from portal inputs

### Current computer name logic

The Azure VM resource name remains stable, for example:

- `vm-avd-avd1-dev-0`

The Windows computer name inside the VM is generated separately and includes a per-deployment seed so that a redeploy into the same resource group name does not reuse the same Entra device hostname.

Example shape:

- `avdavd1dev<seed>0`

Why this matters:

- deleting and recreating the same resource group name can otherwise reproduce the same device hostname
- stale Entra device objects can then block `AADLoginForWindows` with `error_hostname_duplicate`
- the deployment seed prevents that collision on fresh redeployments

But the in-guest Windows computer name is generated from:

- a trimmed VM name prefix
- a 4-character `uniqueString(resourceGroup().id)` seed
- the VM index

Pattern:

- `{computerNamePrefix}{computerNameSeed}{index}`

Example validated result:

- `avdavd1deve5gs0`

This is a deliberate hardening change. It prevents repeated test deployments from reusing the same Windows hostname and colliding with stale Microsoft Entra device objects.

---

## 9. What the Entra join extension does

Extension name:

- `AADLoginForWindows`

This extension performs the Microsoft Entra join and enables Entra-based sign-in behavior for the VM.

What it enables:

- the VM becomes Microsoft Entra joined
- AVD can validate Entra join health
- users can use Entra-backed sign-in for AVD access

Why ordering matters:

- The AVD agent installation runs only after the VM exists, after the managed identity exists, after the required role assignment is present, and after the Entra join extension is installed

That sequencing avoids registration race conditions.

---

## 10. What the InstallAVDAgent extension does

Extension name:

- `InstallAVDAgent`

Publisher/type:

- `Microsoft.Compute`
- `CustomScriptExtension`

This extension uses the Windows Custom Script Extension `fileUris + commandToExecute` pattern.

1. The extension downloads `Install-AVDAgent.ps1` from the repository's raw GitHub URL.
2. The extension runs the downloaded script locally on the VM.

This design avoids embedding the full script body into `commandToExecute`, which can fail on Windows with `The command line is too long`.

### Script flow inside the VM

The inline script performs this sequence:

1. Download AVD BootLoader MSI from Microsoft CDN
2. Download AVD RD Agent MSI from Microsoft CDN
3. Acquire an ARM access token from IMDS using the VM managed identity
4. Call the host pool `retrieveRegistrationToken` API
5. Install BootLoader
6. Install RD Agent
7. Stop AVD services if needed
8. Write the registration token directly to the registry
9. Set `IsRegistered` to `0`
10. Set services to automatic startup
11. Start `RdAgent`
12. Start `RDAgentBootLoader`
13. Poll registration state and service health
14. Exit successfully only if:
    - `IsRegistered = 1`
    - `RdAgent` is running
    - `RDAgentBootLoader` is running

This is the current hardened registration path. It avoids passing the registration token as an MSI property and instead writes the token directly into the registry.

---

## 11. What happens with role assignments

If `avdUserObjectId` is provided, the deployment also grants the user access.

Two user-facing role assignments are created:

1. `Desktop Virtualization User`
   - scope: the desktop application group
   - purpose: allows the user to access the published desktop

2. `Virtual Machine User Login`
   - scope: the resource group
   - purpose: allows Entra-based sign-in to the VMs

There is also a machine-facing role assignment:

- each session host VM's managed identity is granted `Desktop Virtualization Contributor` on the host pool

That machine role is what lets the VM retrieve a registration token from the host pool during provisioning.

If the deployer does not have sufficient permission to create RBAC assignments, leave `avdUserObjectId` empty and assign those roles after deployment.

To get an Entra user object ID:

```bash
az ad user show --id user@domain.com --query id -o tsv
```

---

## 12. What success looks like

A successful deployment ends with:

- all nested ARM deployments in `Succeeded`
- the VM in `Running`
- both VM extensions provisioned successfully
- the session host visible under the host pool
- the session host status `Available`
- AVD health checks succeeded, including:
  - `AADJoinedHealthCheck`
  - `DomainJoinedCheck`
  - `DomainTrustCheck`
  - `MetaDataServiceCheck`
  - `SxSStackListenerCheck`

In the latest validated fresh deployment, the resulting session host reached `Available` without requiring manual cleanup of stale Entra device objects.

---

## 13. Typical resource inventory created

For a single session host deployment with FSLogix and monitoring enabled, the resource group contains:

- 1 virtual machine
- 1 managed disk
- 2 VM extensions
- 1 NIC
- 1 NSG
- 1 NAT gateway
- 1 public IP for the NAT gateway
- 1 virtual network
- 1 host pool
- 1 desktop application group
- 1 workspace
- 1 storage account
- 1 Azure Files share
- 1 Log Analytics workspace
- supporting role assignments

Representative resource names:

- `vm-avd-avd1-dev-0`
- `nic-vm-avd-avd1-dev-0`
- `vnet-avd-avd1-dev`
- `nsg-avd-sessionhosts`
- `hp-avd-avd1-dev`
- `dag-avd-avd1-dev`
- `ws-avd-avd1-dev`
- `log-avd-avd1-dev`

The storage account name depends on the user input and must be globally unique.

---

## 14. What the user gets at the end

The deployment outputs:

- `hostPoolName`
- `workspaceId`
- `vnetId`
- `sessionHostVmNames`
- `fslogixStorageAccount`
- `logAnalyticsWorkspace`
- `avdRolesAssigned`

From the user perspective, the important end state is:

- the AVD workspace exists
- the desktop application group is attached
- the target user has access if `avdUserObjectId` was supplied
- the session host is registered and available
- the user can connect through the AVD web client or Windows App

Primary user-facing connection URLs:

- Web client: `https://client.wvd.microsoft.com/arm/webclient/index.html`
- Windows App download: `https://aka.ms/AVDClientDownload`

---

## 15. Expected timing

Typical timeline for a one-session-host deployment:

- Portal form submission: immediate
- ARM preflight validation: a few seconds
- Network and host pool deployment: under 1 minute
- VM provisioning and extensions: several minutes
- AVD registration and host heartbeat: usually within 5 to 10 minutes total

The latest validated deployment completed the ARM deployment in about 6 minutes 40 seconds and reached an `Available` session host state successfully.

---

## 16. Common failure points this template now avoids

### Duplicate Entra device hostname collisions

Older repeated test deployments could fail Entra join when Windows hostnames were reused.

The current template avoids that by generating a unique in-guest computer name per resource group.

### Corrupted AVD registration token passing

Passing the registration token through nested MSI property escaping proved unreliable.

The current script installs the agent binaries first, then writes the token directly into the registry before restarting the services.

### External GitHub script dependency

The current template downloads `Install-AVDAgent.ps1` from the repository at deployment time so the extension command stays within Windows command-line limits.

---

## 17. What is still outside the scope of the button

The button deploys the landing zone successfully, but some operational steps remain tenant-specific or post-deployment decisions, for example:

- assigning additional users or groups beyond the one optional `avdUserObjectId`
- configuring enterprise policy for FSLogix settings at scale
- attaching additional diagnostic settings if broader monitoring is required
- introducing private endpoints and private DNS if the environment needs fully private access patterns

---

## 18. Summary

When a user clicks **Deploy to Azure**, the Azure portal takes the compiled ARM template from GitHub and performs a full Azure Virtual Desktop deployment.

That deployment:

1. creates the network foundation
2. creates the host pool, application group, and workspace
3. optionally creates secure FSLogix storage
4. optionally creates Log Analytics
5. provisions session host VMs
6. joins them to Microsoft Entra ID
7. retrieves a host pool registration token using the VM managed identity
8. installs and registers the AVD agent
9. assigns user access if an Entra object ID was provided
10. leaves the session host in an `Available` state for user connections

The result is a working AVD landing zone with hardened registration logic, unique Windows hostnames per deployment, outbound-only VM design, secure storage defaults, and a repeatable portal-driven deployment experience.
