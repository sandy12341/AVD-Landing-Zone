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

@description('Authentication type for session host sign-in and join flow')
@allowed(['EntraID', 'HybridJoin'])
param authenticationType string = 'EntraID'

@description('Active Directory domain FQDN (required for HybridJoin)')
param domainFqdn string = ''

@description('Domain join service account in DOMAIN\\username or username@domain format (required for HybridJoin)')
param domainJoinUsername string = ''

@description('Domain join service account password (required for HybridJoin)')
@secure()
param domainJoinPassword string = ''

@description('Optional OU path where computer accounts should be created for HybridJoin (for example OU=AVD,DC=contoso,DC=com)')
param domainJoinOuPath string = ''

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

@description('Per-deployment seed used to avoid reusing the same computer name across redeployments in the same resource group')
param deploymentInstanceSeed string

// Derive a deployment-unique computer name (max 15 chars) to avoid stale Entra device hostname collisions.
var computerNamePrefix = take(replace(replace(vmNamePrefix, 'vm-', ''), '-', ''), 10)
var computerNameSeed = take(uniqueString(resourceGroup().id, deploymentInstanceSeed), 4)
var domainJoinUserEffective = contains(domainJoinUsername, '\\') || contains(domainJoinUsername, '@') ? domainJoinUsername : '${domainJoinUsername}@${domainFqdn}'
var domainJoinOuPathNormalized = empty(domainJoinOuPath) ? '' : replace(domainJoinOuPath, ', ', ',')

// Embed install script content at compile time to avoid runtime dependency on
// external DNS resolution for raw.githubusercontent.com.
var installScriptContent = loadTextContent('../scripts/Install-AVDAgent.ps1')

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
        computerName: '${computerNamePrefix}${computerNameSeed}${i}'
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
  for i in range(0, sessionHostCount): if (authenticationType == 'EntraID') {
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

// Domain join extension for HybridJoin mode
resource hybridDomainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [
  for i in range(0, sessionHostCount): if (authenticationType == 'HybridJoin') {
    parent: sessionHosts[i]
    name: 'JsonADDomainExtension'
    location: location
    tags: tags
    properties: {
      publisher: 'Microsoft.Compute'
      type: 'JsonADDomainExtension'
      typeHandlerVersion: '1.3'
      autoUpgradeMinorVersion: true
      settings: {
        Name: domainFqdn
        User: domainJoinUserEffective
        OUPath: domainJoinOuPathNormalized
        Restart: true
        Options: 3
      }
      protectedSettings: {
        Password: domainJoinPassword
      }
    }
  }
]

// AVD Agent — install via VM RunCommand with inline script content.
// This avoids commandToExecute length limits in CustomScriptExtension.
resource avdAgentEntra 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = [
  for i in range(0, sessionHostCount): if (authenticationType == 'EntraID') {
    parent: sessionHosts[i]
    name: 'InstallAVDAgentEntra'
    location: location
    tags: tags
    properties: {
      source: {
        script: installScriptContent
      }
      parameters: [
        {
          name: 'HostPoolResourceId'
          value: existingHostPool.id
        }
      ]
      timeoutInSeconds: 5400
    }
    dependsOn: [aadJoin[i], vmRoleAssignment[i]]
  }
]

resource avdAgentHybrid 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = [
  for i in range(0, sessionHostCount): if (authenticationType == 'HybridJoin') {
    parent: sessionHosts[i]
    name: 'InstallAVDAgentHybrid'
    location: location
    tags: tags
    properties: {
      source: {
        script: installScriptContent
      }
      parameters: [
        {
          name: 'HostPoolResourceId'
          value: existingHostPool.id
        }
      ]
      timeoutInSeconds: 5400
    }
    dependsOn: [hybridDomainJoin[i], vmRoleAssignment[i]]
  }
]

output vmNames array = [for i in range(0, sessionHostCount): sessionHosts[i].name]
output vmIds array = [for i in range(0, sessionHostCount): sessionHosts[i].id]
