targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Deployment prefix used for naming')
@maxLength(6)
param deploymentPrefix string = 'avd1'

@description('Environment name')
@allowed(['dev', 'test', 'prod'])
param environment string = 'dev'

@description('Number of session host VMs')
@minValue(1)
@maxValue(10)
param sessionHostCount int = 1

@description('VM size for session hosts')
param vmSize string = 'Standard_D2ads_v5'

@description('Preferred AVD delivery mode. Leave empty to preserve the legacy desktop-only behavior driven by hostPoolType.')
@allowed(['', 'PersonalDesktop', 'PooledRemoteApp', 'PooledDesktopAndRemoteApp'])
param avdMode string = ''

@description('Host pool type')
@allowed(['Personal', 'Pooled'])
param hostPoolType string = 'Pooled'

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

@description('Local admin username for session hosts')
param adminUsername string

@description('Local admin password for session hosts')
@secure()
param adminPassword string

@description('Deploy FSLogix profile storage')
param deployFSLogix bool = true

@description('Storage account name for FSLogix profiles (must be globally unique, 3-24 chars, lowercase/numbers only)')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Deploy monitoring (Log Analytics)')
param deployMonitoring bool = true

@description('Name of the existing virtual network to use')
param existingVnetName string

@description('Resource group name that contains the existing virtual network')
param existingVnetResourceGroupName string = resourceGroup().name

@description('Name of the existing subnet for session hosts')
param sessionHostSubnetName string

@description('Name of the existing subnet reserved for private endpoints')
param privateEndpointSubnetName string

@description('Host pool name')
param hostPoolName string

@description('Comma or newline separated Entra Object IDs to grant AVD access. Leave empty to skip role assignments.')
param avdUserObjectIds string = ''

@description('When true, resolve UPN values to Entra Object IDs during deployment using a pre-provisioned resolver application identity.')
param resolveAvdUsersFromUpns bool = false

@description('Comma or newline separated UPNs to resolve when resolveAvdUsersFromUpns is enabled.')
param avdUserUpns string = ''

@description('Tenant ID used for resolver identity token acquisition.')
param resolverTenantId string = tenant().tenantId

@description('Application (client) ID of the pre-provisioned resolver identity.')
param resolverClientId string = ''

@description('Client secret for the resolver identity.')
@secure()
param resolverClientSecret string = ''

@description('RemoteApp definitions used when avdMode publishes RemoteApps. Each item must include name and filePath and can optionally include friendlyName, description, commandLineSetting, and commandLineArguments.')
param remoteApps array = []

@description('Per-deployment seed used to keep session host computer names unique across redeployments in the same resource group.')
param deploymentInstanceSeed string = utcNow('u')

var namingPrefix = '${deploymentPrefix}-${environment}'
var effectiveAvdMode = empty(avdMode) ? (hostPoolType == 'Personal' ? 'PersonalDesktop' : 'PooledDesktop') : avdMode
var effectiveHostPoolType = effectiveAvdMode == 'PersonalDesktop' ? 'Personal' : 'Pooled'
var publishDesktop = effectiveAvdMode == 'PersonalDesktop' || effectiveAvdMode == 'PooledDesktop' || effectiveAvdMode == 'PooledDesktopAndRemoteApp'
var publishRemoteApps = effectiveAvdMode == 'PooledRemoteApp' || effectiveAvdMode == 'PooledDesktopAndRemoteApp'
var desktopAppGroupName = 'dag-avd-${namingPrefix}'
var remoteAppGroupName = 'rag-avd-${namingPrefix}'
var existingVnetId = resourceId(existingVnetResourceGroupName, 'Microsoft.Network/virtualNetworks', existingVnetName)
var sessionHostSubnetId = resourceId(existingVnetResourceGroupName, 'Microsoft.Network/virtualNetworks/subnets', existingVnetName, sessionHostSubnetName)
var privateEndpointSubnetId = resourceId(existingVnetResourceGroupName, 'Microsoft.Network/virtualNetworks/subnets', existingVnetName, privateEndpointSubnetName)
var normalizedAvdUserObjectIds = [for oid in split(replace(replace(avdUserObjectIds, '\r\n', ','), '\n', ','), ','): trim(oid)]
var shouldResolveAvdUsersFromUpns = resolveAvdUsersFromUpns && length(trim(replace(replace(replace(avdUserUpns, '\r', ''), '\n', ''), ',', ''))) > 0
var resolverScriptName = 'resolve-avd-users-${uniqueString(resourceGroup().id, deployment().name)}'
var tags = {
  Environment: environment
  Project: 'AVD-Landing-Zone'
  DeployedBy: 'Bicep'
}

module hostPool '../modules/hostpool.bicep' = {
  name: 'deploy-hostpool'
  params: {
    location: location
    hostPoolName: hostPoolName
    hostPoolType: effectiveHostPoolType
    workspaceName: 'ws-avd-${namingPrefix}'
    desktopAppGroupName: desktopAppGroupName
    remoteAppGroupName: remoteAppGroupName
    publishDesktop: publishDesktop
    publishRemoteApps: publishRemoteApps
    authenticationType: authenticationType
    remoteApps: remoteApps
    tags: tags
  }
}

module sessionHosts '../modules/sessionhosts.bicep' = {
  name: 'deploy-sessionhosts'
  params: {
    location: location
    sessionHostCount: sessionHostCount
    vmSize: vmSize
    subnetId: sessionHostSubnetId
    hostPoolName: hostPool.outputs.hostPoolName
    adminUsername: adminUsername
    adminPassword: adminPassword
    authenticationType: authenticationType
    domainFqdn: domainFqdn
    domainJoinUsername: domainJoinUsername
    domainJoinPassword: domainJoinPassword
    domainJoinOuPath: domainJoinOuPath
    deploymentInstanceSeed: deploymentInstanceSeed
    vmNamePrefix: 'vm-avd-${namingPrefix}'
    tags: tags
  }
}

module fslogix '../modules/fslogix.bicep' = if (deployFSLogix) {
  name: 'deploy-fslogix'
  params: {
    location: location
    storageAccountName: storageAccountName
    sessionHostSubnetId: sessionHostSubnetId
    tags: tags
  }
}

module monitoring '../modules/monitoring.bicep' = if (deployMonitoring) {
  name: 'deploy-monitoring'
  params: {
    location: location
    workspaceName: 'log-avd-${namingPrefix}'
    tags: tags
  }
}

resource resolveAvdUserObjectIds 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (shouldResolveAvdUsersFromUpns) {
  name: resolverScriptName
  location: location
  kind: 'AzurePowerShell'
  properties: {
    azPowerShellVersion: '11.5'
    timeout: 'PT10M'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    forceUpdateTag: uniqueString(avdUserUpns, resolverClientId)
    scriptContent: loadTextContent('../scripts/Resolve-AvdUserObjectIds.ps1')
    environmentVariables: [
      {
        name: 'UPN_LIST'
        value: avdUserUpns
      }
      {
        name: 'TENANT_ID'
        value: resolverTenantId
      }
      {
        name: 'CLIENT_ID'
        value: resolverClientId
      }
      {
        name: 'CLIENT_SECRET'
        secureValue: resolverClientSecret
      }
    ]
  }
}

var resolvedAvdUserObjectIdsCsv = shouldResolveAvdUsersFromUpns ? string(resolveAvdUserObjectIds!.properties.outputs.objectIdsCsv) : ''

module resolvedUpnRoleAssignments '../modules/avdResolvedRoleAssignments.bicep' = if (shouldResolveAvdUsersFromUpns) {
  name: 'resolved-upn-role-assignments'
  params: {
    desktopAppGroupName: desktopAppGroupName
    remoteAppGroupName: remoteAppGroupName
    publishDesktop: publishDesktop
    publishRemoteApps: publishRemoteApps
    authenticationType: authenticationType
    avdUserObjectIdsCsv: resolvedAvdUserObjectIdsCsv
  }
}

resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-08-preview' existing = if (publishDesktop) {
  name: desktopAppGroupName
}

resource remoteAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-08-preview' existing = if (publishRemoteApps) {
  name: remoteAppGroupName
}

resource desktopAvdUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for oid in normalizedAvdUserObjectIds: if (publishDesktop && !empty(oid)) {
  name: guid(resourceGroup().id, desktopAppGroupName, oid, '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
  scope: desktopAppGroup
  dependsOn: [
    hostPool
  ]
  properties: {
    principalId: oid
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
    principalType: 'User'
  }
}]

resource remoteAppAvdUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for oid in normalizedAvdUserObjectIds: if (publishRemoteApps && !empty(oid)) {
  name: guid(resourceGroup().id, remoteAppGroupName, oid, '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
  scope: remoteAppGroup
  dependsOn: [
    hostPool
  ]
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

output hostPoolName string = hostPool.outputs.hostPoolName
output workspaceId string = hostPool.outputs.workspaceId
output desktopAppGroupId string = hostPool.outputs.desktopAppGroupId
output remoteAppGroupId string = hostPool.outputs.remoteAppGroupId
output publishedAppGroupIds array = hostPool.outputs.publishedAppGroupIds
output vnetId string = existingVnetId
output privateEndpointSubnetId string = privateEndpointSubnetId
output sessionHostVmNames array = sessionHosts.outputs.vmNames
output fslogixStorageAccount string = deployFSLogix ? fslogix!.outputs.storageAccountName : 'N/A'
output logAnalyticsWorkspace string = deployMonitoring ? monitoring!.outputs.workspaceName : 'N/A'
output effectiveAvdMode string = effectiveAvdMode
output avdRolesAssigned bool = length(trim(replace(replace(replace(avdUserObjectIds, '\r', ''), '\n', ''), ',', ''))) > 0 || shouldResolveAvdUsersFromUpns
