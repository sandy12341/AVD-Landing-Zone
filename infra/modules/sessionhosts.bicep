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

@description('Host pool registration token')
@secure()
param registrationToken string

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
        computerName: 'avdsh${i}'
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

// AVD Agent extension to register with host pool
resource avdAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [
  for i in range(0, sessionHostCount): {
    parent: sessionHosts[i]
    name: 'Microsoft.PowerShell.DSC'
    location: location
    tags: tags
    properties: {
      publisher: 'Microsoft.Powershell'
      type: 'DSC'
      typeHandlerVersion: '2.73'
      autoUpgradeMinorVersion: true
      settings: {
        modulesUrl: 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_1.0.02802.442.zip'
        configurationFunction: 'Configuration.ps1\\AddSessionHost'
        properties: {
          hostPoolName: hostPoolName
          registrationInfoTokenCredential: {
            UserName: 'PLACEHOLDER'
            Password: 'PrivateSettingsRef:RegistrationInfoToken'
          }
          aadJoin: true
        }
      }
      protectedSettings: {
        items: {
          RegistrationInfoToken: registrationToken
        }
      }
    }
    dependsOn: [aadJoin[i]]
  }
]

output vmNames array = [for i in range(0, sessionHostCount): sessionHosts[i].name]
output vmIds array = [for i in range(0, sessionHostCount): sessionHosts[i].id]
