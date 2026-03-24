@description('Azure region for the VNet')
param location string

@description('Name of the VNet')
param vnetName string

@description('VNet address prefix')
param vnetAddressPrefix string = '10.20.0.0/16'

@description('Session hosts subnet prefix')
param sessionHostSubnetPrefix string = '10.20.1.0/24'

@description('Private endpoints subnet prefix')
param privateEndpointSubnetPrefix string = '10.20.2.0/24'

@description('Tags for all resources')
param tags object = {}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'snet-avd-sessionhosts'
        properties: {
          addressPrefix: sessionHostSubnetPrefix
          networkSecurityGroup: {
            id: nsgSessionHosts.id
          }
        }
      }
      {
        name: 'snet-avd-privateendpoints'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
        }
      }
    ]
  }
}

resource nsgSessionHosts 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: 'nsg-avd-sessionhosts'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowRDP'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output sessionHostSubnetId string = vnet.properties.subnets[0].id
output privateEndpointSubnetId string = vnet.properties.subnets[1].id
