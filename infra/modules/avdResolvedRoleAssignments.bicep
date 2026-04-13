targetScope = 'resourceGroup'

@description('Desktop app group name for AVD role assignment scope.')
param desktopAppGroupName string

@description('RemoteApp app group name for AVD role assignment scope.')
param remoteAppGroupName string

@description('True when desktop app group is published.')
param publishDesktop bool

@description('True when remote app group is published.')
param publishRemoteApps bool

@description('Authentication type for VM login role behavior.')
@allowed(['EntraID', 'HybridJoin'])
param authenticationType string

@description('Comma or newline separated Entra Object IDs resolved from UPNs.')
param avdUserObjectIdsCsv string

var normalizedAvdUserObjectIds = [for oid in split(replace(replace(avdUserObjectIdsCsv, '\r\n', ','), '\n', ','), ','): trim(oid)]

resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-08-preview' existing = if (publishDesktop) {
  name: desktopAppGroupName
}

resource remoteAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-08-preview' existing = if (publishRemoteApps) {
  name: remoteAppGroupName
}

resource desktopAvdUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for oid in normalizedAvdUserObjectIds: if (publishDesktop && !empty(oid)) {
  name: guid(resourceGroup().id, desktopAppGroupName, oid, '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
  scope: desktopAppGroup
  properties: {
    principalId: oid
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
    principalType: 'User'
  }
}]

resource remoteAppAvdUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for oid in normalizedAvdUserObjectIds: if (publishRemoteApps && !empty(oid)) {
  name: guid(resourceGroup().id, remoteAppGroupName, oid, '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
  scope: remoteAppGroup
  properties: {
    principalId: oid
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
    principalType: 'User'
  }
}]

resource vmLoginRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for oid in normalizedAvdUserObjectIds: if (authenticationType == 'EntraID' && !empty(oid)) {
  name: guid(resourceGroup().id, oid, 'fb879df8-f326-4884-b1cf-06f3ad86be52')
  properties: {
    principalId: oid
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'fb879df8-f326-4884-b1cf-06f3ad86be52')
    principalType: 'User'
  }
}]
