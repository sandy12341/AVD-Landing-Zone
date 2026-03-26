@description('Azure region')
param location string

@description('Host pool name')
param hostPoolName string

@description('Host pool friendly name')
param hostPoolFriendlyName string = 'AVD Host Pool'

@description('Host pool type')
@allowed(['Personal', 'Pooled'])
param hostPoolType string = 'Pooled'

@description('Load balancer type for pooled host pool')
@allowed(['BreadthFirst', 'DepthFirst'])
param loadBalancerType string = 'BreadthFirst'

@description('Max session limit per host')
param maxSessionLimit int = 10

@description('Workspace name')
param workspaceName string

@description('Desktop application group name')
param desktopAppGroupName string = ''

@description('RemoteApp application group name')
param remoteAppGroupName string = ''

@description('Publish a desktop application group')
param publishDesktop bool = true

@description('Publish a RemoteApp application group')
param publishRemoteApps bool = false

@description('RemoteApp definitions. Each item must include name and filePath and can optionally include friendlyName, description, commandLineSetting, and commandLineArguments.')
param remoteApps array = []

@description('Tags for all resources')
param tags object = {}

@description('Deployment timestamp (auto-populated)')
param baseTime string = utcNow()

var preferredAppGroupType = publishDesktop ? 'Desktop' : 'RailApplications'
var publishedAppGroupIds = concat(
  publishDesktop ? [desktopAppGroup.id] : [],
  publishRemoteApps ? [remoteAppGroup.id] : []
)

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-08-preview' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: {
    hostPoolType: hostPoolType
    loadBalancerType: loadBalancerType
    maxSessionLimit: maxSessionLimit
    preferredAppGroupType: preferredAppGroupType
    friendlyName: hostPoolFriendlyName
    validationEnvironment: false
    startVMOnConnect: true
    customRdpProperty: 'targetisaadjoined:i:1;enablerdsaadauth:i:1;redirectclipboard:i:1;audiomode:i:0;videoplaybackmode:i:1;use multimon:i:1;enablecredsspsupport:i:1;redirectwebauthn:i:1;'
    registrationInfo: {
      expirationTime: dateTimeAdd(baseTime, 'PT48H')
      registrationTokenOperation: 'Update'
    }
  }
}

resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-08-preview' = if (publishDesktop) {
  name: desktopAppGroupName
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
    friendlyName: 'AVD Desktop'
  }
}

resource remoteAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-08-preview' = if (publishRemoteApps) {
  name: remoteAppGroupName
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'RemoteApp'
    hostPoolArmPath: hostPool.id
    friendlyName: 'AVD RemoteApp'
  }
}

resource remoteApplications 'Microsoft.DesktopVirtualization/applicationGroups/applications@2024-04-08-preview' = [for remoteApp in (publishRemoteApps ? remoteApps : []): {
  name: remoteApp.name
  parent: remoteAppGroup
  properties: {
    applicationType: 'InBuilt'
    commandLineArguments: remoteApp.?commandLineArguments ?? ''
    commandLineSetting: remoteApp.?commandLineSetting ?? 'DoNotAllow'
    description: remoteApp.?description ?? 'Published RemoteApp'
    filePath: remoteApp.filePath
    friendlyName: remoteApp.?friendlyName ?? remoteApp.name
    showInPortal: true
  }
}]

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-08-preview' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    friendlyName: 'AVD Workspace'
    applicationGroupReferences: publishedAppGroupIds
  }
}

output hostPoolId string = hostPool.id
output hostPoolName string = hostPool.name
output desktopAppGroupId string = publishDesktop ? desktopAppGroup.id : ''
output remoteAppGroupId string = publishRemoteApps ? remoteAppGroup.id : ''
output publishedAppGroupIds array = publishedAppGroupIds
output workspaceId string = workspace.id
