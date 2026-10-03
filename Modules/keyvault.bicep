targetScope = 'resourceGroup'

@description('Azure region for Key Vault.')
param location string

@description('20MED workspace name.')
param workspaceName string

@description('Deployment environment.')
param environment string

@description('Common resource tags.')
param tags object

var keyVaultName = 'kv20-${toLower(environment)}-${toLower(workspaceName)}'

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags

  properties: {
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'

    sku: {
      family: 'A'
      name: 'standard'
    }

    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
  }
}

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
