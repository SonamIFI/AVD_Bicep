targetScope = 'resourceGroup'

@description('Azure region for the route table.')
param location string

@description('20MED workspace name.')
param workspaceName string

@description('Deployment environment.')
param environment string

@description('Common resource tags.')
param tags object

@description('Name of the existing virtual network.')
param vnetName string

@description('Name of the AVD subnet.')
param avdSubnetName string

@description('Address prefix of the AVD subnet.')
param avdSubnetPrefix string

@description('Resource ID of the AVD subnet network security group.')
param avdNsgId string

@description('Private IP address of Azure Firewall.')
param firewallPrivateIp string

var routeTableName = 'rt-20med-avd-${toLower(environment)}-${toLower(workspaceName)}'

resource routeTable 'Microsoft.Network/routeTables@2025-09-01' = {
  name: routeTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'DefaultRouteToAzureFirewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource avdSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: avdSubnetName
  properties: {
    addressPrefix: avdSubnetPrefix
    networkSecurityGroup: {
      id: avdNsgId
    }
    routeTable: {
      id: routeTable.id
    }
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

output routeTableId string = routeTable.id
output routeTableName string = routeTable.name
