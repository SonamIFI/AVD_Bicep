targetScope = 'resourceGroup'

@description('Azure region for the session hosts.')
param location string

@description('20MED workspace name.')
param workspaceName string

@description('Common resource tags.')
param tags object

@description('Existing AVD host pool name.')
param hostPoolName string

@description('Existing VNet name.')
param vnetName string

@description('Existing AVD subnet name.')
param avdSubnetName string

@description('Number of session hosts to deploy.')
param sessionHostCount int = 1

@description('Azure VM size for the session host.')
param vmSize string = 'Standard_E4s_v5'

@description('Local administrator username.')
param adminUsername string

@secure()
@description('Local administrator password.')
param adminPassword string

@secure()
@description('AVD host pool registration token.')
param registrationToken string = ''

param avdUserGroupObjectId string
param fslogixStorageAccountName string
param fslogixFileShareName string

resource profileStorage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: fslogixStorageAccountName
}

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' existing = {
  name: hostPoolName
}

// ------------------------------------------------------------
// Existing Network
// ------------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource avdSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: avdSubnetName
}

// ------------------------------------------------------------
// Network Interfaces
// ------------------------------------------------------------

resource networkInterfaces 'Microsoft.Network/networkInterfaces@2024-05-01' = [
  for i in range(0, sessionHostCount): {
    name: 'nic-${toLower(workspaceName)}-${i + 1}'
    location: location
    tags: tags

    properties: {
      ipConfigurations: [
        {
          name: 'ipconfig1'

          properties: {
            privateIPAllocationMethod: 'Dynamic'

            subnet: {
              id: avdSubnet.id
            }
          }
        }
      ]
    }
  }
]

// ------------------------------------------------------------
// Session Host Virtual Machines
// ------------------------------------------------------------

resource sessionHosts 'Microsoft.Compute/virtualMachines@2026-04-01' = [
  for i in range(0, sessionHostCount): {
    name: 'vm-${toLower(workspaceName)}-${i + 1}'
    location: location
    tags: tags

    identity: {
      type: 'SystemAssigned'
    }

    properties: {
      hardwareProfile: {
        vmSize: vmSize
      }

      osProfile: {
        computerName: 'avd-${i + 1}'
        adminUsername: adminUsername
        adminPassword: adminPassword
      }

      storageProfile: {
        imageReference: {
          publisher: 'MicrosoftWindowsDesktop'
          offer: 'Windows-11'
          sku: 'win11-24h2-avd'
          version: 'latest'
        }

        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      }

      networkProfile: {
        networkInterfaces: [
          {
            id: networkInterfaces[i].id
            properties: {
              primary: true
            }
          }
        ]
      }
    }
  }
]

// ------------------------------------------------------------
// Microsoft Entra ID Login Extension
// ------------------------------------------------------------

resource aadLoginExtension 'Microsoft.Compute/virtualMachines/extensions@2026-04-01' = [
  for i in range(0, sessionHostCount): {
    name: 'AADLoginForWindows'
    parent: sessionHosts[i]
    location: location

    properties: {
      publisher: 'Microsoft.Azure.ActiveDirectory'
      type: 'AADLoginForWindows'
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
      enableAutomaticUpgrade: false
    }
    dependsOn: [
      configureProfiles[i]
    ]
  }
]

resource vmUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for hostIndex in range(0, sessionHostCount): {
    name: guid(sessionHosts[hostIndex].id, avdUserGroupObjectId, 'vm-user-login')
    scope: sessionHosts[hostIndex]
    properties: {
      principalId: avdUserGroupObjectId
      principalType: 'Group'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'fb879df8-f326-4884-b1cf-06f3ad86be52')
    }
  }
]

resource configureProfiles 'Microsoft.Compute/virtualMachines/runCommands@2024-11-01' = [
  for hostIndex in range(0, sessionHostCount): {
    name: 'Configure-FSLogix'
    parent: sessionHosts[hostIndex]
    location: location
    properties: {
      source: {
        script: loadTextContent('../Scripts/configure-fslogix.ps1')
      }
      parameters: [
        { name: 'StorageAccountName', value: fslogixStorageAccountName }
        { name: 'StorageSuffix', value: az.environment().suffixes.storage }
        { name: 'FileShareName', value: fslogixFileShareName }
        { name: 'UserGroupObjectId', value: avdUserGroupObjectId }
        { name: 'InitializeShare', value: string(hostIndex == 0) }
      ]
      protectedParameters: hostIndex == 0 ? [
        { name: 'StorageKey', value: profileStorage.listKeys().keys[0].value }
      ] : []
      asyncExecution: false
      timeoutInSeconds: 1800
      treatFailureAsDeploymentFailure: true
    }
  }
]

// ------------------------------------------------------------
// AVD Session Host Registration
// ------------------------------------------------------------

resource avdSessionHostExtension 'Microsoft.Compute/virtualMachines/extensions@2026-04-01' = [
  for i in range(0, sessionHostCount): {
    name: 'Microsoft.PowerShell.DSC'
    parent: sessionHosts[i]
    location: location

    properties: {
      publisher: 'Microsoft.Powershell'
      type: 'DSC'
      typeHandlerVersion: '2.83'

      settings: {
        #disable-next-line no-hardcoded-env-urls
        modulesUrl: 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02797.442.zip'
        configurationFunction: 'Configuration.ps1\\AddSessionHost'
        properties: {
          HostPoolName: hostPoolName
          aadJoin: true
        }
      }

      protectedSettings: {
        properties: {
          RegistrationInfoToken: empty(registrationToken) ? hostPool.listRegistrationTokens().value[0].token : registrationToken
        }
      }

      autoUpgradeMinorVersion: true
    }

    dependsOn: [
      aadLoginExtension[i]
    ]
  }
]

// ------------------------------------------------------------
// Outputs
// ------------------------------------------------------------

output sessionHostCount int = sessionHostCount

output sessionHostNames array = [
  for i in range(0, sessionHostCount): sessionHosts[i].name
]

output sessionHostIds array = [
  for i in range(0, sessionHostCount): sessionHosts[i].id
]
