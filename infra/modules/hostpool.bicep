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

@description('Application group name')
param appGroupName string

@description('Tags for all resources')
param tags object = {}

@description('Deployment timestamp (auto-populated)')
param baseTime string = utcNow()

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-08-preview' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: {
    hostPoolType: hostPoolType
    loadBalancerType: loadBalancerType
    maxSessionLimit: maxSessionLimit
    preferredAppGroupType: 'Desktop'
    friendlyName: hostPoolFriendlyName
    validationEnvironment: false
    startVMOnConnect: true
    registrationInfo: {
      expirationTime: dateTimeAdd(baseTime, 'PT48H')
      registrationTokenOperation: 'Update'
    }
  }
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-08-preview' = {
  name: appGroupName
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
    friendlyName: 'AVD Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-08-preview' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    friendlyName: 'AVD Workspace'
    applicationGroupReferences: [
      appGroup.id
    ]
  }
}

output hostPoolId string = hostPool.id
output hostPoolName string = hostPool.name
output appGroupId string = appGroup.id
output workspaceId string = workspace.id
