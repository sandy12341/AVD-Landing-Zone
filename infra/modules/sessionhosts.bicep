@description('Azure region')
param location string

@description('Number of session hosts to deploy')
@minValue(1)
@maxValue(10)
param sessionHostCount int = 1

@description('VM size for session hosts')
param vmSize string = 'Standard_D2ads_v5'

@description('Subnet resource ID for session hosts')
param subnetId string

@description('Host pool name to register VMs with')
param hostPoolName string

@description('Local admin username')
param adminUsername string

@description('Local admin password')
@secure()
param adminPassword string

@description('OS image reference')
param imageReference object = {
  publisher: 'microsoftwindowsdesktop'
  offer: 'windows-11'
  sku: 'win11-24h2-avd'
  version: 'latest'
}

@description('Tags for all resources')
param tags object = {}

@description('Name prefix for session hosts')
param vmNamePrefix string = 'vm-avd'

// Derive a unique short computer name (max 15 chars) from vmNamePrefix
var shortPrefix = take(replace(replace(vmNamePrefix, 'vm-', ''), '-', ''), 12)

// Reference existing host pool for role assignment and token retrieval
resource existingHostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-08-preview' existing = {
  name: hostPoolName
}

// Desktop Virtualization Contributor role — allows VMs to retrieve registration token
var desktopVirtContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '082f0a83-3be5-4ba1-904c-961cca79b387')

resource sessionHosts 'Microsoft.Compute/virtualMachines@2024-07-01' = [
  for i in range(0, sessionHostCount): {
    name: '${vmNamePrefix}-${i}'
    location: location
    tags: tags
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      hardwareProfile: {
        vmSize: vmSize
      }
      storageProfile: {
        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
          deleteOption: 'Delete'
        }
        imageReference: imageReference
      }
      osProfile: {
        computerName: '${shortPrefix}${i}'
        adminUsername: adminUsername
        adminPassword: adminPassword
        windowsConfiguration: {
          enableAutomaticUpdates: true
          patchSettings: {
            patchMode: 'AutomaticByOS'
          }
        }
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: nics[i].id
            properties: {
              deleteOption: 'Delete'
            }
          }
        ]
      }
      licenseType: 'Windows_Client'
    }
  }
]

resource nics 'Microsoft.Network/networkInterfaces@2024-01-01' = [
  for i in range(0, sessionHostCount): {
    name: 'nic-${vmNamePrefix}-${i}'
    location: location
    tags: tags
    properties: {
      ipConfigurations: [
        {
          name: 'ipconfig1'
          properties: {
            privateIPAllocationMethod: 'Dynamic'
            subnet: {
              id: subnetId
            }
          }
        }
      ]
    }
  }
]

// Role assignment — allow each VM to retrieve host pool registration token
resource vmRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for i in range(0, sessionHostCount): {
    name: guid(existingHostPool.id, sessionHosts[i].id, 'avd-contributor')
    scope: existingHostPool
    properties: {
      roleDefinitionId: desktopVirtContributorRoleId
      principalId: sessionHosts[i].identity.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

// Entra ID (AAD) join extension
resource aadJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [
  for i in range(0, sessionHostCount): {
    parent: sessionHosts[i]
    name: 'AADLoginForWindows'
    location: location
    tags: tags
    properties: {
      publisher: 'Microsoft.Azure.ActiveDirectory'
      type: 'AADLoginForWindows'
      typeHandlerVersion: '2.2'
      autoUpgradeMinorVersion: true
    }
  }
]

// AVD Agent — install via Custom Script Extension (stable MSI download URLs)
// Installs BootLoader + RDAgent MSIs, then writes the registration token to the registry
// and restarts both services so the agent registers with the host pool.
resource avdAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [
  for i in range(0, sessionHostCount): {
    parent: sessionHosts[i]
    name: 'InstallAVDAgent'
    location: location
    tags: tags
    properties: {
      publisher: 'Microsoft.Compute'
      type: 'CustomScriptExtension'
      typeHandlerVersion: '1.10'
      autoUpgradeMinorVersion: true
      settings: {
        fileUris: [
          'https://raw.githubusercontent.com/sandy12341/AVD-Landing-Zone/master/infra/scripts/Install-AVDAgent.ps1'
        ]
      }
      protectedSettings: {
        commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File Install-AVDAgent.ps1 -HostPoolResourceId "${existingHostPool.id}"'
      }
    }
    dependsOn: [aadJoin[i], vmRoleAssignment[i]]
  }
]

output vmNames array = [for i in range(0, sessionHostCount): sessionHosts[i].name]
output vmIds array = [for i in range(0, sessionHostCount): sessionHosts[i].id]
