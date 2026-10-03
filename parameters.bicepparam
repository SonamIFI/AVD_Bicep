using './main.bicep'

param location = 'Central India'

param resourceGroupName = 'rg-20med-avd-dataengineering-uat'

param workspaceName = 'DataEngineering'

param environment = 'uat'

param adminUsername = 'avdadmin'

param adminPassword = readEnvironmentVariable('AVD_ADMIN_PASSWORD')
param avdUserGroupObjectId = readEnvironmentVariable('AVD_USER_GROUP_OBJECT_ID')
param avdServicePrincipalObjectId = readEnvironmentVariable('AVD_SERVICE_PRINCIPAL_OBJECT_ID')

param maxAuthorizedUsers = 10

param maxSessionsPerHost = 3

param sessionHostCount = 1

param deploySessionHosts = true

param vmSize = 'Standard_E4s_v5'

param fileShareQuotaGiB = 500

param retentionInDays = 30


