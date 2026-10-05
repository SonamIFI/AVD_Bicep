using './main.bicep'

param location = 'Central India'

param environment = 'uat'

param activeWorkspace = 'DataEngineering'
param phaseAcceptanceReference = 'INITIAL-DATA-ENGINEERING-WORK-ORDER'

param adminUsername = 'avdadmin'

param adminPassword = readEnvironmentVariable('AVD_ADMIN_PASSWORD', '')
param avdUserGroupObjectId = readEnvironmentVariable('AVD_USER_GROUP_OBJECT_ID', '00000000-0000-0000-0000-000000000000')
param avdServicePrincipalObjectId = readEnvironmentVariable('AVD_SERVICE_PRINCIPAL_OBJECT_ID', '00000000-0000-0000-0000-000000000000')

param maxAuthorizedUsers = 10

param maxSessionsPerHost = 3

param sessionHostCount = 1

param deploySessionHosts = true

param vmSize = 'Standard_E4s_v5'

param fileShareQuotaGiB = 500

param retentionInDays = 30


