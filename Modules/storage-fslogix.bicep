targetScope = 'resourceGroup'

@description('Azure region for the FSLogix storage account.')
param location string

@description('20MED workspace name.')
param workspaceName string

@description('Deployment environment.')
param environment string

@description('Common resource tags.')
param tags object

param avdUserGroupObjectId string
param vnetId string
param privateEndpointSubnetId string

@description('Storage account SKU.')
@allowed([
  'Premium_LRS'
])
param storageSku string = 'Premium_LRS'

@description('FSLogix file share name.')
param fileShareName string = 'de-fslogix'

@description('File share quota in GiB.')
param fileShareQuotaGiB int = 500

var storageAccountName = 'st20${toLower(environment)}${toLower(workspaceName)}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: tags

  sku: {
    name: storageSku
  }

  kind: 'FileStorage'

  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
      defaultSharePermission: 'None'
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2024-01-01' = {
  name: 'default'
  parent: storageAccount

  properties: {
    protocolSettings: {
      smb: {
        multichannel: {
          enabled: true
        }
      }
    }
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  name: fileShareName
  parent: fileService

  properties: {
    accessTier: 'Premium'
    shareQuota: fileShareQuotaGiB
    fileSharePaidBursting: {
      paidBurstingEnabled: false
    }
  }
}

resource shareUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(fileShare.id, avdUserGroupObjectId, 'smb-contributor')
  scope: fileShare
  properties: {
    principalId: avdUserGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb')
  }
}

resource filePrivateDns 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.file.${az.environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource fileDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: filePrivateDns
  name: '${toLower(workspaceName)}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource filePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${storageAccountName}-file'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'files'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['file']
        }
      }
    ]
  }
}

resource fileDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: filePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'files'
        properties: {
          privateDnsZoneId: filePrivateDns.id
        }
      }
    ]
  }
}

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output fileShareName string = fileShare.name
output fileShareId string = fileShare.id
