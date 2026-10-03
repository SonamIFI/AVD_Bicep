targetScope = 'resourceGroup'

@description('Azure region for Azure Firewall resources.')
param location string

@description('20MED workspace name.')
param workspaceName string

@description('Deployment environment.')
param environment string

@description('Common resource tags.')
param tags object

@description('Azure Firewall subnet resource ID.')
param firewallSubnetId string

@description('Azure Firewall management subnet resource ID.')
param firewallManagementSubnetId string

@description('AVD subnet address prefix used as the firewall rule source.')
param avdSubnetPrefix string

@description('Approved FQDN destinations for HTTPS/HTTP access from the AVD subnet.')
param approvedFqdns array = []

@description('Approved NTP server IP addresses. Basic cannot filter NTP by FQDN.')
param ntpServerIpAddresses array = []

@description('Approved client IPs or CIDRs for direct RDP Shortpath UDP egress. Empty disables direct Shortpath rules.')
param rdpShortpathDestinationCidrs array = []

var firewallName = 'afw-20med-${toLower(environment)}-${toLower(workspaceName)}'
var firewallPolicyName = 'afwp-20med-${toLower(environment)}-${toLower(workspaceName)}-basic'
var publicIpName = 'pip-afw-20med-${toLower(environment)}-${toLower(workspaceName)}'
var managementPublicIpName = 'pip-afw-mgmt-20med-${toLower(environment)}-${toLower(workspaceName)}'
var ruleCollectionGroupName = 'rcg-20med-avd-egress'

resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    ddosSettings: {
      protectionMode: 'VirtualNetworkInherited'
    }
  }
}

resource firewallManagementPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: managementPublicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    ddosSettings: {
      protectionMode: 'VirtualNetworkInherited'
    }
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: firewallPolicyName
  location: location
  tags: tags
  properties: {
    threatIntelMode: 'Alert'
    sku: {
      tier: 'Basic'
    }
  }
}

resource firewallRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: firewallPolicy
  name: ruleCollectionGroupName
  properties: {
    priority: 100
    ruleCollections: [
      {
        name: 'Allow-Windows-Activation'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            name: 'Allow-Azure-KMS'
            ruleType: 'NetworkRule'
            sourceAddresses: [avdSubnetPrefix]
            ipProtocols: ['TCP']
            destinationAddresses: ['20.118.99.224', '40.83.235.53', '23.102.135.246']
            destinationPorts: ['1688']
          }
        ]
      }
      {
        name: 'Allow-AVD-Network-Dependencies'
        priority: 105
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: concat([
          {
            name: 'Allow-AVD-Service-Traffic'
            ruleType: 'NetworkRule'
            sourceAddresses: [avdSubnetPrefix]
            ipProtocols: ['TCP']
            destinationAddresses: ['WindowsVirtualDesktop']
            destinationPorts: ['443']
          }
          {
            name: 'Allow-Azure-Monitor'
            ruleType: 'NetworkRule'
            sourceAddresses: [avdSubnetPrefix]
            ipProtocols: ['TCP']
            destinationAddresses: ['AzureMonitor']
            destinationPorts: ['443']
          }
          {
            name: 'Allow-AVD-Relayed-Shortpath'
            ruleType: 'NetworkRule'
            sourceAddresses: [avdSubnetPrefix]
            ipProtocols: ['UDP']
            destinationAddresses: ['WindowsVirtualDesktop']
            destinationPorts: ['3478']
          }
        ], !empty(ntpServerIpAddresses) ? [
          {
            name: 'Allow-Approved-NTP'
            ruleType: 'NetworkRule'
            sourceAddresses: [avdSubnetPrefix]
            ipProtocols: ['UDP']
            destinationAddresses: ntpServerIpAddresses
            destinationPorts: ['123']
          }
        ] : [], !empty(rdpShortpathDestinationCidrs) ? [
          {
            name: 'Allow-Approved-Direct-Shortpath'
            ruleType: 'NetworkRule'
            sourceAddresses: [avdSubnetPrefix]
            ipProtocols: ['UDP']
            destinationAddresses: rdpShortpathDestinationCidrs
            destinationPorts: ['49152-65535']
          }
        ] : [])
      }
      {
        name: 'Allow-Approved-HTTPS'
        priority: 110
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: concat([
          {
            name: 'Allow-FSLogix-Installer'
            ruleType: 'ApplicationRule'
            sourceAddresses: [avdSubnetPrefix]
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              'aka.ms'
              'download.microsoft.com'
            ]
          }
          {
            name: 'Allow-Certificate-Checks'
            ruleType: 'ApplicationRule'
            sourceAddresses: [avdSubnetPrefix]
            protocols: [{ protocolType: 'Http', port: 80 }]
            targetFqdns: [
              'oneocsp.microsoft.com'
              'www.microsoft.com'
              '*.aikcertaia.microsoft.com'
              'azcsprodeusaikpublish.blob.${az.environment().suffixes.storage}'
              '*.microsoftaik.azure.net'
              'ctldl.windowsupdate.com'
              '*.digicert.com'
            ]
          }
          {
            name: 'Allow-AVD-Agent-Dependencies'
            ruleType: 'ApplicationRule'
            sourceAddresses: [avdSubnetPrefix]
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              'catalogartifact.azureedge.net'
              '*.prod.warm.ingest.monitor.${az.environment().suffixes.storage}'
              'gcs.prod.monitoring.${az.environment().suffixes.storage}'
              'mrsglobalsteus2prod.blob.${az.environment().suffixes.storage}'
              '*.service.windows.cloud.microsoft'
              '*.windows.cloud.microsoft'
              '*.windows.static.microsoft'
            ]
          }
          {
            name: 'Allow-Windows-Virtual-Desktop'
            description: 'Allow required Azure Virtual Desktop service endpoints.'
            ruleType: 'ApplicationRule'
            sourceAddresses: [
              avdSubnetPrefix
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            fqdnTags: [
              'WindowsVirtualDesktop'
            ]
          }
          {
            name: 'Allow-AVD-DSC-Artifacts'
            description: 'Allow the AVD DSC extension package download.'
            ruleType: 'ApplicationRule'
            sourceAddresses: [
              avdSubnetPrefix
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              #disable-next-line no-hardcoded-env-urls
              'wvdportalstorageblob.blob.core.windows.net'
            ]
          }
          {
            name: 'Allow-Entra-Device-Registration'
            description: 'Allow Microsoft Entra join and VM sign-in endpoints.'
            ruleType: 'ApplicationRule'
            sourceAddresses: [
              avdSubnetPrefix
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              #disable-next-line no-hardcoded-env-urls
              'login.microsoftonline.com'
              'device.${replace(replace(az.environment().authentication.loginEndpoint, 'https://', ''), '/', '')}'
              'login.windows.net'
              'enterpriseregistration.windows.net'
              'pas.windows.net'
            ]
          }
        ], !empty(approvedFqdns) ? [
          {
            name: 'Allow-Approved-FQDNs'
            description: 'Allow only explicitly approved HTTP/HTTPS destinations from the AVD subnet.'
            ruleType: 'ApplicationRule'
            sourceAddresses: [
              avdSubnetPrefix
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
              {
                protocolType: 'Http'
                port: 80
              }
            ]
            targetFqdns: approvedFqdns
          }
        ] : [])
      }
      {
        name: 'Allow-Windows-Operational-Services'
        priority: 120
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            name: 'Allow-Windows-Update-And-Diagnostics'
            ruleType: 'ApplicationRule'
            sourceAddresses: [avdSubnetPrefix]
            protocols: [{ protocolType: 'Https', port: 443 }]
            fqdnTags: ['WindowsUpdate', 'WindowsDiagnostics']
          }
          {
            name: 'Allow-Windows-Connectivity-Check'
            ruleType: 'ApplicationRule'
            sourceAddresses: [avdSubnetPrefix]
            protocols: [{ protocolType: 'Http', port: 80 }]
            targetFqdns: ['www.msftconnecttest.com']
          }
          {
            name: 'Allow-Telemetry-OneDrive-And-DNS-HTTPS'
            ruleType: 'ApplicationRule'
            sourceAddresses: [avdSubnetPrefix]
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              '*.events.data.microsoft.com'
              '*.prod.do.dsp.mp.microsoft.com'
              '*.sfx.ms'
              '*.digicert.com'
              '*.azure-dns.com'
              '*.azure-dns.net'
            ]
          }
          {
            name: 'Allow-Service-Bus-Diagnostics'
            ruleType: 'ApplicationRule'
            sourceAddresses: [avdSubnetPrefix]
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              #disable-next-line no-hardcoded-env-urls
              '*.servicebus.windows.net'
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: firewallName
  location: location
  tags: tags
  dependsOn: [
    firewallRuleCollectionGroup
  ]
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Basic'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'firewall-ipconfig'
        properties: {
          subnet: {
            id: firewallSubnetId
          }
          publicIPAddress: {
            id: firewallPublicIp.id
          }
        }
      }
    ]
    managementIpConfiguration: {
      name: 'firewall-management-ipconfig'
      properties: {
        subnet: {
          id: firewallManagementSubnetId
        }
        publicIPAddress: {
          id: firewallManagementPublicIp.id
        }
      }
    }
  }
}

output firewallId string = firewall.id
output firewallName string = firewall.name
output firewallPolicyId string = firewallPolicy.id
output firewallPolicyName string = firewallPolicy.name
output firewallPublicIpId string = firewallPublicIp.id
output firewallPublicIpAddress string = firewallPublicIp.properties.ipAddress
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
