// ─────────────────────────────────────────────────────────────────────
// Azure Virtual Desktop + Landing Zone — Main Deployment
// Deploys: VNet, Host Pool, Workspace, Session Hosts (Entra ID join),
//          FSLogix storage, and Log Analytics monitoring
// ─────────────────────────────────────────────────────────────────────

targetScope = 'resourceGroup'

// ── Parameters ──

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

@description('Host pool type')
@allowed(['Personal', 'Pooled'])
param hostPoolType string = 'Pooled'

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
param storageAccountName string = 'stavdavd1dev'

@description('Deploy monitoring (Log Analytics)')
param deployMonitoring bool = true

@description('VNet address prefix')
param vnetAddressPrefix string = '10.20.0.0/16'

@description('Session hosts subnet prefix')
param sessionHostSubnetPrefix string = '10.20.1.0/24'

@description('Private endpoints subnet prefix')
param privateEndpointSubnetPrefix string = '10.20.2.0/24'

@description('Entra Object ID of the user to grant AVD access. Leave empty to skip role assignments.')
param avdUserObjectId string = ''

// ── Variables ──

var namingPrefix = '${deploymentPrefix}-${environment}'
var tags = {
  Environment: environment
  Project: 'AVD-Landing-Zone'
  DeployedBy: 'Bicep'
}

// ── Networking ──

module network 'modules/network.bicep' = {
  name: 'deploy-network'
  params: {
    location: location
    vnetName: 'vnet-avd-${namingPrefix}'
    vnetAddressPrefix: vnetAddressPrefix
    sessionHostSubnetPrefix: sessionHostSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    tags: tags
  }
}

// ── Host Pool + Workspace ──

module hostPool 'modules/hostpool.bicep' = {
  name: 'deploy-hostpool'
  params: {
    location: location
    hostPoolName: 'hp-avd-${namingPrefix}'
    hostPoolType: hostPoolType
    workspaceName: 'ws-avd-${namingPrefix}'
    appGroupName: 'dag-avd-${namingPrefix}'
    tags: tags
  }
}

// ── Session Hosts (auto-registered via host pool token) ──

module sessionHosts 'modules/sessionhosts.bicep' = {
  name: 'deploy-sessionhosts'
  params: {
    location: location
    sessionHostCount: sessionHostCount
    vmSize: vmSize
    subnetId: network.outputs.sessionHostSubnetId
    hostPoolName: hostPool.outputs.hostPoolName
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmNamePrefix: 'vm-avd-${namingPrefix}'
    tags: tags
  }
}

// ── FSLogix Storage ──

module fslogix 'modules/fslogix.bicep' = if (deployFSLogix) {
  name: 'deploy-fslogix'
  params: {
    location: location
    storageAccountName: storageAccountName
    tags: tags
  }
}

// ── Monitoring ──

module monitoring 'modules/monitoring.bicep' = if (deployMonitoring) {
  name: 'deploy-monitoring'
  params: {
    location: location
    workspaceName: 'log-avd-${namingPrefix}'
    tags: tags
  }
}

// ── AVD User Role Assignments (native Bicep) ──

// Desktop Virtualization User on the App Group
resource avdUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdUserObjectId)) {
  name: guid(resourceGroup().id, 'dag-avd-${namingPrefix}', avdUserObjectId, '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
  scope: appGroup
  properties: {
    principalId: avdUserObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
    principalType: 'User'
  }
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-08-preview' existing = {
  name: 'dag-avd-${namingPrefix}'
  dependsOn: [hostPool]
}

// Virtual Machine User Login on the Resource Group
resource vmLoginRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdUserObjectId)) {
  name: guid(resourceGroup().id, avdUserObjectId, 'fb879df8-f326-4884-b1cf-06f3ad86be52')
  properties: {
    principalId: avdUserObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'fb879df8-f326-4884-b1cf-06f3ad86be52')
    principalType: 'User'
  }
}

// ── Outputs ──

output hostPoolName string = hostPool.outputs.hostPoolName
output workspaceId string = hostPool.outputs.workspaceId
output vnetId string = network.outputs.vnetId
output sessionHostVmNames array = sessionHosts.outputs.vmNames
output fslogixStorageAccount string = deployFSLogix ? fslogix.outputs.storageAccountName : 'N/A'
output logAnalyticsWorkspace string = deployMonitoring ? monitoring.outputs.workspaceName : 'N/A'
output avdRolesAssigned bool = !empty(avdUserObjectId)
