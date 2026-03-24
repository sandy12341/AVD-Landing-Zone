@description('Azure region')
param location string

@description('Log Analytics workspace name')
param workspaceName string

@description('Retention in days')
param retentionDays int = 30

@description('Tags for all resources')
param tags object = {}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionDays
  }
}

output workspaceId string = logAnalytics.id
output workspaceName string = logAnalytics.name
