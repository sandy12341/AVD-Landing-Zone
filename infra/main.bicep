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

@description('Email (UPN) of the user to grant AVD access. Leave empty to skip role assignments.')
param avdUserEmail string = ''

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
    allowedSubnetId: network.outputs.sessionHostSubnetId
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

// ── AVD User Role Assignments (via Deployment Script) ──

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (!empty(avdUserEmail)) {
  name: 'uami-avd-deploy-${namingPrefix}'
  location: location
  tags: tags
}

// Grant UAMI "User Access Administrator" on the resource group so it can assign roles
var userAccessAdminRoleId = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
resource uamiRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdUserEmail)) {
  name: guid(resourceGroup().id, uami!.id, userAccessAdminRoleId)
  properties: {
    principalId: uami!.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', userAccessAdminRoleId)
    principalType: 'ServicePrincipal'
  }
}

// Storage account for deployment scripts (shared key access required by ACI)
resource dsStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (!empty(avdUserEmail)) {
  name: take('stds${replace(namingPrefix, '-', '')}${uniqueString(resourceGroup().id)}', 24)
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
  }
  tags: tags
}

resource assignAvdRoles 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (!empty(avdUserEmail)) {
  name: 'ds-assign-avd-roles-${namingPrefix}'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami!.id}': {}
    }
  }
  dependsOn: [
    uamiRoleAssignment
  ]
  properties: {
    storageAccountSettings: {
      storageAccountName: dsStorage!.name
    }
    azCliVersion: '2.63.0'
    retentionInterval: 'PT1H'
    timeout: 'PT10M'
    environmentVariables: [
      { name: 'USER_EMAIL', value: avdUserEmail }
      { name: 'APP_GROUP_ID', value: hostPool.outputs.appGroupId }
      { name: 'RG_ID', value: resourceGroup().id }
    ]
    scriptContent: '''
      set -e
      # Desktop Virtualization User on the App Group
      az role assignment create \
        --assignee "$USER_EMAIL" \
        --role "1d18fff3-a72a-46b5-b4a9-0b37a71c1920" \
        --scope "$APP_GROUP_ID"
      # Virtual Machine User Login on the Resource Group
      az role assignment create \
        --assignee "$USER_EMAIL" \
        --role "fb879df8-f326-4884-b1cf-06f3ad86be52" \
        --scope "$RG_ID"
      echo "{\"rolesAssigned\": true}" > $AZ_SCRIPTS_OUTPUT_PATH
    '''
  }
  tags: tags
}

// ── Outputs ──

output hostPoolName string = hostPool.outputs.hostPoolName
output workspaceId string = hostPool.outputs.workspaceId
output vnetId string = network.outputs.vnetId
output sessionHostVmNames array = sessionHosts.outputs.vmNames
output fslogixStorageAccount string = deployFSLogix ? fslogix.outputs.storageAccountName : 'N/A'
output logAnalyticsWorkspace string = deployMonitoring ? monitoring.outputs.workspaceName : 'N/A'
output avdRolesAssigned bool = !empty(avdUserEmail)
