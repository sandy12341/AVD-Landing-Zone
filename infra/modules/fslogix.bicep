@description('Azure region')
param location string

@description('Storage account name for FSLogix profiles')
param storageAccountName string

@description('File share name')
param fileShareName string = 'fslogix-profiles'

@description('File share quota in GB')
param fileShareQuotaGiB int = 100

@description('Tags for all resources')
param tags object = {}

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
    allowSharedKeyAccess: true
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileServices
  name: fileShareName
  properties: {
    shareQuota: fileShareQuotaGiB
    enabledProtocols: 'SMB'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output fileShareName string = fileShare.name
