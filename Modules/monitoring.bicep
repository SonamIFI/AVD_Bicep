targetScope = 'resourceGroup'

@description('Azure region for monitoring resources.')
param location string

@description('20MED workspace name.')
param workspaceName string

@description('Deployment environment.')
param environment string

@description('Common resource tags.')
param tags object

@description('Existing AVD host pool resource ID.')
param hostPoolId string

@description('Existing Azure Firewall resource ID.')
param firewallId string

@description('Log Analytics workspace SKU.')
param logAnalyticsSku string = 'PerGB2018'

@description('Interactive retention period in days.')
param retentionInDays int = 30

var workspaceNameValue = 'law-20med-${toLower(environment)}-${toLower(workspaceName)}'

// ------------------------------------------------------------
// Log Analytics Workspace
// ------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceNameValue
  location: location
  tags: tags

  properties: {
    sku: {
      name: logAnalyticsSku
    }

    retentionInDays: retentionInDays

    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }

    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ------------------------------------------------------------
// Existing AVD Host Pool
// ------------------------------------------------------------

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' existing = {
  name: last(split(hostPoolId, '/'))
}

// ------------------------------------------------------------
// Existing Azure Firewall
// ------------------------------------------------------------

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' existing = {
  name: last(split(firewallId, '/'))
}

// ------------------------------------------------------------
// AVD Host Pool Diagnostic Settings
// ------------------------------------------------------------

resource hostPoolDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${toLower(workspaceName)}-hostpool'
  scope: hostPool

  properties: {
    workspaceId: logAnalytics.id

    logAnalyticsDestinationType: 'Dedicated'

    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// ------------------------------------------------------------
// Azure Firewall Diagnostic Settings
// ------------------------------------------------------------

resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${toLower(workspaceName)}-firewall'
  scope: firewall

  properties: {
    workspaceId: logAnalytics.id

    logAnalyticsDestinationType: 'Dedicated'

    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]

    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}


// ------------------------------------------------------------
// Outputs
// ------------------------------------------------------------

output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsWorkspaceName string = logAnalytics.name
