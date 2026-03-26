@description('Storage account name for FSLogix profiles')
param storageAccountName string

@description('Azure region')
param location string

@description('Tags for all resources')
param tags object = {}

@description('Session host subnet ID for VNet service endpoint access')
param sessionHostSubnetId string = ''

var storageNetworkAcls = {
  defaultAction: 'Deny'
  bypass: 'AzureServices'
  virtualNetworkRules: !empty(sessionHostSubnetId) ? [
    {
      id: sessionHostSubnetId
      action: 'Allow'
    }
  ] : []
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
    }
    networkAcls: storageNetworkAcls
  }
}
