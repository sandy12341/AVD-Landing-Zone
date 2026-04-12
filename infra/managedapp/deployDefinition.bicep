targetScope = 'resourceGroup'

@description('Azure region for the managed application definition')
param location string = resourceGroup().location

@description('Name of the managed application definition')
param managedApplicationDefinitionName string = 'avd-existing-network'

@description('Display name shown in the Azure service catalog')
param definitionDisplayName string = 'Azure Virtual Desktop + ALZ'

@description('Description shown in the Azure service catalog')
param definitionDescription string = 'Azure Virtual Desktop deployment that uses an existing VNet and existing subnets selected through a managed application portal wizard.'

@description('URI of the managed application package zip file')
param packageFileUri string

@description('Principal ID that receives access to the managed resource group')
param principalId string

@description('Role definition ID granted to the managing principal')
param roleDefinitionId string = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'

@description('Managed resource group lock level')
@allowed(['ReadOnly'])
param lockLevel string = 'ReadOnly'

resource managedApplicationDefinition 'Microsoft.Solutions/applicationDefinitions@2021-07-01' = {
  name: managedApplicationDefinitionName
  location: location
  properties: {
    lockLevel: lockLevel
    description: definitionDescription
    displayName: definitionDisplayName
    packageFileUri: packageFileUri
    authorizations: [
      {
        principalId: principalId
        roleDefinitionId: roleDefinitionId
      }
    ]
    deploymentPolicy: {
      deploymentMode: 'Incremental'
    }
    managementPolicy: {
      mode: 'Managed'
    }
    isEnabled: true
  }
}

output managedApplicationDefinitionId string = managedApplicationDefinition.id
