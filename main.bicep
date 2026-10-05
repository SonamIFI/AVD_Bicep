targetScope = 'subscription'

@description('Azure region for the Data Engineering AVD environment.')
param location string = 'Central India'

@description('Select exactly one AVD workspace phase for this deployment.')
@allowed([
  'DataEngineering'
  'Prospecting'
  'Sales'
  'ReferenceData'
  'Finance'
])
param activeWorkspace string = 'DataEngineering'

@description('Work Order or written acceptance reference authorizing this phase.')
param phaseAcceptanceReference string = 'INITIAL-DATA-ENGINEERING-WORK-ORDER'

@description('Local administrator username for the session host.')
param adminUsername string

@secure()
@description('Local administrator password for the session host.')
param adminPassword string = ''

@description('Entra security group object ID; deploy.ps1 can create the group.')
@minLength(36)
@maxLength(36)
param avdUserGroupObjectId string

@minLength(36)
@maxLength(36)
param avdServicePrincipalObjectId string

@secure()
@description('Temporary AVD host pool registration token.')
param registrationToken string = ''

@description('Deploy AVD session hosts.')
param deploySessionHosts bool = false

@description('Deployment environment.')
@allowed([
  'uat'
  'prod'
])
param environment string = 'uat'

@description('Maximum number of authorized users for this workspace.')
param maxAuthorizedUsers int = 10

@description('Maximum number of concurrent sessions allowed per session host.')
param maxSessionsPerHost int = 3

@description('Approved FQDNs allowed for AVD internet egress through Azure Firewall.')
param approvedFqdns array = []

@description('Approved NTP server IP addresses; Basic cannot resolve NTP FQDN rules.')
param ntpServerIpAddresses array = []

@description('Approved remote client IPs/CIDRs for direct RDP Shortpath UDP; empty disables direct Shortpath.')
param rdpShortpathDestinationCidrs array = []

@description('Number of initial AVD session hosts.')
param sessionHostCount int = 1

@description('VM size for the AVD session host.')
param vmSize string = 'Standard_E4s_v5'

@description('FSLogix file share quota in GiB.')
param fileShareQuotaGiB int = 500

@description('Log Analytics retention in days.')
param retentionInDays int = 30

@description('Common resource tags applied to all resources.')
param tags object = {}

var deployDataEngineering = activeWorkspace == 'DataEngineering'
var deployProspecting = activeWorkspace == 'Prospecting'
var deploySales = activeWorkspace == 'Sales'
var deployReferenceData = activeWorkspace == 'ReferenceData'
var deployFinance = activeWorkspace == 'Finance'
var workspaceName = deployDataEngineering ? 'DataEngineering' : deployProspecting ? 'Prospecting' : deploySales ? 'Sales' : deployReferenceData ? 'ReferenceData' : deployFinance ? 'Finance' : 'InvalidPhase'
var resourceGroupName = 'rg-20med-avd-${toLower(workspaceName)}-${environment}'
var sharedCoreWorkspaceName = 'DataEngineering'
var resourceTags = union(tags, {
  Environment: environment
  Workspace: workspaceName
  PhaseAcceptanceReference: phaseAcceptanceReference
  ManagedBy: 'Bicep'
  Owner: 'IFI Tech'
})

// ------------------------------------------------------------
// Resource Group
// ------------------------------------------------------------

resource avdResourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ------------------------------------------------------------
// Key Vault
// ------------------------------------------------------------

module keyVault 'modules/keyvault.bicep' = {
  name: '${sharedCoreWorkspaceName}-keyvault'
  scope: avdResourceGroup

  params: {
    location: location
    workspaceName: sharedCoreWorkspaceName
    environment: environment
    tags: resourceTags
  }
}

// ------------------------------------------------------------
// Networking
// ------------------------------------------------------------

module networking 'modules/networking.bicep' = {
  name: '${sharedCoreWorkspaceName}-networking'
  scope: avdResourceGroup

  params: {
    location: location
    workspaceName: sharedCoreWorkspaceName
    environment: environment
    tags: resourceTags
  }
}

// ------------------------------------------------------------
// Azure Firewall
// ------------------------------------------------------------

module firewall 'modules/firewall.bicep' = {
  name: '${sharedCoreWorkspaceName}-firewall'
  scope: avdResourceGroup

  params: {
    location: location
    workspaceName: sharedCoreWorkspaceName
    environment: environment
    tags: resourceTags

    firewallSubnetId: networking.outputs.firewallSubnetId
    firewallManagementSubnetId: networking.outputs.firewallManagementSubnetId
    avdSubnetPrefix: '10.10.1.0/24'

    approvedFqdns: approvedFqdns
    ntpServerIpAddresses: ntpServerIpAddresses
    rdpShortpathDestinationCidrs: rdpShortpathDestinationCidrs
  }
}

// ------------------------------------------------------------
// Routing
// ------------------------------------------------------------

module routing 'modules/routing.bicep' = {
  name: '${sharedCoreWorkspaceName}-routing'
  scope: avdResourceGroup

  params: {
    location: location
    workspaceName: sharedCoreWorkspaceName
    environment: environment
    tags: resourceTags

    vnetName: networking.outputs.vnetName
    avdSubnetName: networking.outputs.avdSubnetName
    avdSubnetPrefix: '10.10.1.0/24'
    avdNsgId: networking.outputs.avdNsgId

    firewallPrivateIp: firewall.outputs.firewallPrivateIp
  }
}

// ------------------------------------------------------------
// Azure Virtual Desktop
// ------------------------------------------------------------

module avd 'modules/avd.bicep' = {
  name: '${workspaceName}-avd'
  scope: avdResourceGroup

  params: {
    location: location
    workspaceName: workspaceName
    environment: environment
    tags: resourceTags

    maxAuthorizedUsers: maxAuthorizedUsers
    maxSessionsPerHost: maxSessionsPerHost
    createRegistrationToken: deploySessionHosts
    avdUserGroupObjectId: avdUserGroupObjectId
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
}

// ------------------------------------------------------------
// AVD Session Hosts
// ------------------------------------------------------------

module sessionHosts 'modules/session-host.bicep' = if (deploySessionHosts) {
  name: '${workspaceName}-session-hosts'
  scope: avdResourceGroup

  params: {
    location: location
    workspaceName: workspaceName
    tags: resourceTags

    hostPoolName: avd.outputs.hostPoolName

    vnetName: networking.outputs.vnetName
    avdSubnetName: networking.outputs.avdSubnetName

    sessionHostCount: sessionHostCount
    vmSize: vmSize

    adminUsername: adminUsername
    adminPassword: adminPassword

    registrationToken: registrationToken
    avdUserGroupObjectId: avdUserGroupObjectId
    fslogixStorageAccountName: fslogixStorage.outputs.storageAccountName
    fslogixFileShareName: fslogixStorage.outputs.fileShareName
  }

  dependsOn: [
    routing
  ]
}

// ------------------------------------------------------------
// FSLogix Storage
// ------------------------------------------------------------

module fslogixStorage 'modules/storage-fslogix.bicep' = {
  name: '${workspaceName}-fslogix-storage'
  scope: avdResourceGroup

  params: {
    location: location
    workspaceName: workspaceName
    environment: environment
    tags: resourceTags

    storageSku: 'Premium_LRS'
    fileShareName: 'de-fslogix'
    fileShareQuotaGiB: fileShareQuotaGiB
    avdUserGroupObjectId: avdUserGroupObjectId
    vnetId: networking.outputs.vnetId
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
  }
}

// ------------------------------------------------------------
// Monitoring
// ------------------------------------------------------------

module monitoring 'modules/monitoring.bicep' = {
  name: '${workspaceName}-monitoring'
  scope: avdResourceGroup

  params: {
    location: location
    workspaceName: workspaceName
    environment: environment
    tags: tags

    hostPoolId: avd.outputs.hostPoolId
    firewallId: firewall.outputs.firewallId

    logAnalyticsSku: 'PerGB2018'
    retentionInDays: retentionInDays
  }
}

output hostPoolName string = avd.outputs.hostPoolName
output fslogixStorageAccountName string = fslogixStorage.outputs.storageAccountName
output fslogixFileShareName string = fslogixStorage.outputs.fileShareName
output avdUserGroupObjectId string = avdUserGroupObjectId
output resourceGroupName string = avdResourceGroup.name
output sessionHostIds array = deploySessionHosts ? sessionHosts!.outputs.sessionHostIds : []
