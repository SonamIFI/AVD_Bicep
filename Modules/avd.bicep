targetScope = 'resourceGroup'

@description('Azure region for AVD resources.')
param location string

@description('20MED workspace name.')
param workspaceName string

@description('Deployment environment.')
param environment string

@description('Common resource tags.')
param tags object

@description('Entra security group object ID authorized to use the desktop.')
param avdUserGroupObjectId string

@description('Azure Virtual Desktop enterprise application service principal object ID.')
param avdServicePrincipalObjectId string

@description('Planned user count; informational only, not an access limit.')
param maxAuthorizedUsers int = 10

@description('Maximum number of concurrent sessions allowed per session host.')
param maxSessionsPerHost int = 3

@description('Generate a registration token when deploying session hosts.')
param createRegistrationToken bool = false

@description('Registration token expiry in UTC; refreshed on each deployment.')
param registrationTokenExpiration string = dateTimeAdd(utcNow(), 'P1D')

@description('Friendly name of the AVD host pool.')
param hostPoolName string = 'hp-20med-${toLower(environment)}-${toLower(workspaceName)}'

@description('Friendly name of the AVD application group.')
param applicationGroupName string = 'dag-20med-${toLower(environment)}-${toLower(workspaceName)}'

@description('Friendly name of the AVD workspace.')
param avdWorkspaceName string = 'ws-20med-${toLower(environment)}-${toLower(workspaceName)}'

@description('Host pool type.')
@allowed([
  'Pooled'
  'Personal'
])
param hostPoolType string = 'Pooled'

@description('Load balancing algorithm for the pooled host pool.')
@allowed([
  'BreadthFirst'
  'DepthFirst'
])
param loadBalancerType string = 'BreadthFirst'

@description('Preferred desktop application group type.')
@allowed([
  'Desktop'
  'RemoteApp'
])
param applicationGroupType string = 'Desktop'

// ------------------------------------------------------------
// AVD Host Pool
// ------------------------------------------------------------

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolName
  location: location
  tags: tags

  properties: {
    hostPoolType: hostPoolType
    loadBalancerType: loadBalancerType
    preferredAppGroupType: applicationGroupType

    maxSessionLimit: maxSessionsPerHost

    validationEnvironment: environment == 'uat'

    startVMOnConnect: true

    customRdpProperty: 'drivestoredirect:s:;usbdevicestoredirect:s:;redirectclipboard:i:0;redirectprinters:i:0;audiomode:i:0;videoplaybackmode:i:1;devicestoredirect:s:*;redirectcomports:i:1;redirectsmartcards:i:1;enablecredsspsupport:i:1;redirectwebauthn:i:1;use multimon:i:1;targetisaadjoined:i:1;'

    registrationInfo: createRegistrationToken ? {
      expirationTime: registrationTokenExpiration
      registrationTokenOperation: 'Update'
    } : null

    ring: 0
  }
}

// ------------------------------------------------------------
// Desktop Application Group
// ------------------------------------------------------------

resource applicationGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: applicationGroupName
  location: location
  tags: tags

  properties: {
    hostPoolArmPath: hostPool.id
    applicationGroupType: applicationGroupType
  }
}

// ------------------------------------------------------------
// AVD Workspace
// ------------------------------------------------------------

resource desktopUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(applicationGroup.id, avdUserGroupObjectId, 'desktop-user')
  scope: applicationGroup
  properties: {
    principalId: avdUserGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
  }
}

resource avdPowerOnAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, avdServicePrincipalObjectId, 'avd-power-on')
  properties: {
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '489581de-a3bd-480d-9518-53dea7416b33')
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' = {
  name: avdWorkspaceName
  location: location
  tags: tags

  properties: {
    friendlyName: '${workspaceName} AVD Workspace'
    description: '20MED ${workspaceName} Azure Virtual Desktop workspace. Max authorized users: ${maxAuthorizedUsers}.'
    applicationGroupReferences: [
      applicationGroup.id
    ]
  }
}

output hostPoolId string = hostPool.id
output hostPoolName string = hostPool.name

output applicationGroupId string = applicationGroup.id
output applicationGroupName string = applicationGroup.name

output workspaceId string = workspace.id
output workspaceName string = workspace.name
