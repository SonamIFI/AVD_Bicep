targetScope = 'resourceGroup'

@description('Azure region for the networking resources.')
param location string

@description('20MED workspace name.')
param workspaceName string

@description('Deployment environment.')
param environment string

@description('Common resource tags.')
param tags object

// ------------------------------------------------------------
// Network Configuration
// ------------------------------------------------------------

@description('Virtual network address space.')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('AVD session host subnet address prefix.')
param avdSubnetPrefix string = '10.10.1.0/24'

@description('Azure Firewall subnet address prefix.')
param firewallSubnetPrefix string = '10.10.2.0/24'

@description('Azure Firewall management subnet address prefix.')
param firewallManagementSubnetPrefix string = '10.10.5.0/26'

@description('Management subnet address prefix.')
param managementSubnetPrefix string = '10.10.3.0/24'

@description('Private Endpoint subnet address prefix.')
param privateEndpointSubnetPrefix string = '10.10.4.0/24'

// ------------------------------------------------------------
// Resource Names
// ------------------------------------------------------------

var vnetName = 'vnet-20med-avd-${toLower(environment)}-${toLower(workspaceName)}'

var avdSubnetName = 'snet-avd-${toLower(workspaceName)}'

var firewallSubnetName = 'AzureFirewallSubnet'

var firewallManagementSubnetName = 'AzureFirewallManagementSubnet'

var managementSubnetName = 'snet-management-${toLower(workspaceName)}'

var privateEndpointSubnetName = 'snet-private-endpoint-${toLower(workspaceName)}'

var avdNsgName = 'nsg-avd-${toLower(environment)}-${toLower(workspaceName)}'

var managementNsgName = 'nsg-management-${toLower(environment)}-${toLower(workspaceName)}'

// ------------------------------------------------------------
// NSG - AVD
// ------------------------------------------------------------

resource avdNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: avdNsgName
  location: location
  tags: tags

  properties: {
    securityRules: [
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ------------------------------------------------------------
// NSG - Management
// ------------------------------------------------------------

resource managementNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: managementNsgName
  location: location
  tags: tags

  properties: {
    securityRules: []
  }
}

// ------------------------------------------------------------
// Virtual Network
// ------------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags

  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    privateEndpointVNetPolicies: 'Disabled'
    subnets: [
      // ------------------------------------------------------
      // AVD Subnet
      // ------------------------------------------------------

      {
        name: avdSubnetName

        properties: {
          addressPrefix: avdSubnetPrefix

          networkSecurityGroup: {
            id: avdNsg.id
          }
        }
      }

      // ------------------------------------------------------
      // Azure Firewall Subnet
      // ------------------------------------------------------

      {
        name: firewallSubnetName

        properties: {
          addressPrefix: firewallSubnetPrefix
        }
      }

      // ------------------------------------------------------
      // Azure Firewall Management Subnet
      // ------------------------------------------------------

      {
        name: firewallManagementSubnetName

        properties: {
          addressPrefix: firewallManagementSubnetPrefix
        }
      }

      // ------------------------------------------------------
      // Management Subnet
      // ------------------------------------------------------

      {
        name: managementSubnetName

        properties: {
          addressPrefix: managementSubnetPrefix

          networkSecurityGroup: {
            id: managementNsg.id
          }
        }
      }

      // ------------------------------------------------------
      // Private Endpoint Subnet
      // ------------------------------------------------------

      {
        name: privateEndpointSubnetName

        properties: {
          addressPrefix: privateEndpointSubnetPrefix

          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ------------------------------------------------------------
// Outputs
// ------------------------------------------------------------

output vnetName string = vnet.name

output vnetId string = vnet.id

output avdSubnetName string = avdSubnetName

output avdNsgId string = avdNsg.id

output avdSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  vnet.name,
  avdSubnetName
)

output firewallSubnetName string = firewallSubnetName

output firewallSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  vnet.name,
  firewallSubnetName
)

output firewallManagementSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  vnet.name,
  firewallManagementSubnetName
)

output managementSubnetName string = managementSubnetName

output managementSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  vnet.name,
  managementSubnetName
)

output privateEndpointSubnetName string = privateEndpointSubnetName

output privateEndpointSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  vnet.name,
  privateEndpointSubnetName
)
