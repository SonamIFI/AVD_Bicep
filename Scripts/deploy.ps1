[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][ValidateCount(1, 10)][guid[]]$UserObjectIds,
    [string]$UserGroupName = 'sg-20med-avd-dataengineering-uat-users',
    [string]$DeploymentLocation = 'centralindia',
    [securestring]$AdminPassword,
    [switch]$ExcludeStorageFromMfaPolicies,
    [guid[]]$MfaPolicyIds = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-AzureCli {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' ')" }
    if ($result) { return ($result | ConvertFrom-Json) }
}

function Invoke-Graph {
    param([string]$Path, [string]$Method = 'GET', [object]$Body)
    $request = @{
        Uri = "https://graph.microsoft.com/v1.0/$Path"
        Method = $Method
        Headers = @{ Authorization = "Bearer $script:graphToken" }
        ContentType = 'application/json'
    }
    if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 30 -Compress }
    Invoke-RestMethod @request
}

function Get-GraphCollection {
    param([string]$Path)
    do {
        $page = Invoke-Graph -Path $Path
        $page.value
        $next = $page.PSObject.Properties['@odata.nextLink']
        $Path = if ($next) { $next.Value.Replace('https://graph.microsoft.com/v1.0/', '') } else { $null }
    } while ($Path)
}

if ($ExcludeStorageFromMfaPolicies -and $MfaPolicyIds.Count -eq 0) {
    throw 'Specify the exact -MfaPolicyIds approved for storage-app exclusion.'
}
Invoke-AzureCli @('account', 'set', '--subscription', $SubscriptionId.ToString()) | Out-Null
$account = Invoke-AzureCli @('account', 'show')
$cloud = Invoke-AzureCli @('cloud', 'show')
if ($cloud.name -ne 'AzureCloud') { throw 'This cloud-only configuration targets Azure Public cloud.' }
$script:graphToken = (Invoke-AzureCli @('account', 'get-access-token', '--resource-type', 'ms-graph')).accessToken

$groupFilter = [uri]::EscapeDataString("displayName eq '$($UserGroupName.Replace("'", "''"))'")
$groups = @(Get-GraphCollection "groups?`$filter=$groupFilter&`$select=id,securityEnabled,onPremisesSyncEnabled")
if ($groups.Count -gt 1) { throw 'Multiple groups have this name. Use a unique group name.' }
if ($groups.Count -eq 0) {
    $group = Invoke-Graph -Path 'groups' -Method POST -Body @{
        displayName = $UserGroupName
        mailEnabled = $false
        mailNickname = "avd-$([guid]::NewGuid().ToString('N'))"
        securityEnabled = $true
    }
} else {
    $group = $groups[0]
    if (-not $group.securityEnabled -or $group.onPremisesSyncEnabled) {
        throw 'The access group must be a cloud-only security group.'
    }
}
$members = @(Get-GraphCollection "groups/$($group.id)/members")
$memberIds = @($members | ForEach-Object { $_.id })
foreach ($userId in @($UserObjectIds | Select-Object -Unique)) {
    $user = Invoke-Graph "users/$($userId)?`$select=id,userType,onPremisesSyncEnabled,accountEnabled"
    if ($user.onPremisesSyncEnabled -or $user.userType -ne 'Member') {
        throw "User $userId is not a cloud-only member account."
    }
    if (-not $user.accountEnabled) { throw "User $userId is disabled." }
    if ($userId.ToString() -notin $memberIds) {
        Invoke-Graph -Path "groups/$($group.id)/members/`$ref" -Method POST -Body @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$userId"
        } | Out-Null
    }
}

$avdAppId = '9cdead84-a844-4324-93f2-b2e6bb768d07'
$servicePrincipals = @(Get-GraphCollection "servicePrincipals?`$filter=appId eq '$avdAppId'")
if ($servicePrincipals.Count -eq 0) {
    $avdPrincipal = Invoke-Graph -Path 'servicePrincipals' -Method POST -Body @{ appId = $avdAppId }
} else { $avdPrincipal = $servicePrincipals[0] }

if (-not $AdminPassword) {
    if (-not [string]::IsNullOrWhiteSpace($env:AVD_ADMIN_PASSWORD)) {
        $AdminPassword = ConvertTo-SecureString $env:AVD_ADMIN_PASSWORD -AsPlainText -Force
    } else {
        $AdminPassword = Read-Host 'Session-host local administrator password' -AsSecureString
    }
}
$previousPassword = $env:AVD_ADMIN_PASSWORD
$previousGroup = $env:AVD_USER_GROUP_OBJECT_ID
$previousPrincipal = $env:AVD_SERVICE_PRINCIPAL_OBJECT_ID
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
try {
    $env:AVD_ADMIN_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    $env:AVD_USER_GROUP_OBJECT_ID = $group.id
    $env:AVD_SERVICE_PRINCIPAL_OBJECT_ID = $avdPrincipal.id
    $parametersFile = Join-Path $PSScriptRoot '../parameters.bicepparam'
    Write-Host 'Deploying infrastructure and private FSLogix storage...'
    $outputs = Invoke-AzureCli @(
        'deployment', 'sub', 'create', '--name', '20med-avd-infrastructure',
        '--location', $DeploymentLocation, '--parameters', $parametersFile, 'deploySessionHosts=false',
        '--query', 'properties.outputs'
    )
    $storageName = $outputs.fslogixStorageAccountName.value
    $resourceGroup = $outputs.resourceGroupName.value
    $script:graphToken = (Invoke-AzureCli @('account', 'get-access-token', '--resource-type', 'ms-graph')).accessToken
    $fileHost = "$storageName.file.core.windows.net"
    $privateHost = "$storageName.privatelink.file.core.windows.net"
    $storageFilter = [uri]::EscapeDataString("displayName eq '[Storage Account] $fileHost'")
    $storageApps = @(Get-GraphCollection "applications?`$filter=$storageFilter")
    if ($storageApps.Count -ne 1) {
        throw 'Storage Kerberos app not found uniquely. If directory replication is pending, rerun this script.'
    }
    $storageApp = $storageApps[0]
    $privateIdentifiers = @($storageApp.identifierUris | Where-Object { $_.EndsWith($fileHost) } |
        ForEach-Object { $_.Replace($fileHost, $privateHost) })
    if ($privateIdentifiers.Count -eq 0) { throw 'Storage app has no expected Kerberos identifiers.' }
    Invoke-Graph -Path "applications/$($storageApp.id)" -Method PATCH -Body @{
        tags = @(@($storageApp.tags) + 'kdc_enable_cloud_group_sids' | Select-Object -Unique)
        identifierUris = @(@($storageApp.identifierUris) + $privateIdentifiers | Select-Object -Unique)
    } | Out-Null
    Invoke-AzureCli @('ad', 'app', 'permission', 'admin-consent', '--id', $storageApp.appId) | Out-Null

    $policies = @(Get-GraphCollection 'identity/conditionalAccess/policies')
    $policiesToExclude = @()
    foreach ($policy in $policies) {
        $grant = $policy.grantControls
        $strength = if ($grant) { $grant.PSObject.Properties['authenticationStrength'] } else { $null }
        $requiresMfa = $grant -and ('mfa' -in $grant.builtInControls -or ($strength -and $strength.Value))
        $apps = $policy.conditions.applications
        $applicationFilter = $apps.PSObject.Properties['applicationFilter']
        if ($policy.state -ne 'disabled' -and $requiresMfa -and $applicationFilter -and
            $applicationFilter.Value -and $storageApp.appId -notin $apps.excludeApplications) {
            throw "Policy '$($policy.displayName)' uses an application filter. Review its storage-app applicability before deploying hosts."
        }
        $appliesToStorage = 'All' -in $apps.includeApplications -or $storageApp.appId -in $apps.includeApplications
        if ($policy.state -eq 'disabled' -or -not $requiresMfa -or -not $appliesToStorage -or
            $storageApp.appId -in $apps.excludeApplications) { continue }
        if (-not $ExcludeStorageFromMfaPolicies -or $policy.id -notin @($MfaPolicyIds | ForEach-Object ToString)) {
            throw "Policy '$($policy.displayName)' may require MFA for storage. Approve its ID with -MfaPolicyIds and -ExcludeStorageFromMfaPolicies, then rerun. No policy was changed."
        }
        $policiesToExclude += $policy
    }
    foreach ($policy in $policiesToExclude) {
        $apps = $policy.conditions.applications
        $apps.excludeApplications = @(@($apps.excludeApplications) + $storageApp.appId | Select-Object -Unique)
        Invoke-Graph -Path "identity/conditionalAccess/policies/$($policy.id)" -Method PATCH -Body @{
            conditions = @{ applications = $apps }
        } | Out-Null
        Write-Host "Excluded only the storage app from approved MFA policy '$($policy.displayName)'."
    }

    Write-Host 'Deploying and registering session hosts...'
    $hostOutputs = Invoke-AzureCli @(
        'deployment', 'sub', 'create', '--name', '20med-avd-session-hosts',
        '--location', $DeploymentLocation, '--parameters', $parametersFile, 'deploySessionHosts=true',
        '--query', 'properties.outputs'
    )
    $hostIds = @($hostOutputs.sessionHostIds.value)
    if ($hostIds.Count -eq 0) { throw 'The host deployment returned no VM IDs to restart.' }
    Write-Host 'Restarting deployed hosts to activate FSLogix drivers and Kerberos settings...'
    Invoke-AzureCli -Arguments (@('vm', 'restart', '--ids') + $hostIds) | Out-Null
    Invoke-AzureCli @('storage', 'share-rm', 'show', '--resource-group', $resourceGroup,
        '--storage-account', $storageName, '--name', $outputs.fslogixFileShareName.value,
        '--query', '{name:name,quota:shareQuota}') | Format-List
    $hostResponse = Invoke-AzureCli @('rest', '--method', 'get', '--url',
        "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$($outputs.hostPoolName.value)/sessionHosts?api-version=2024-04-03")
    $sessionHosts = @($hostResponse.value)
    $sessionHosts | ForEach-Object { [pscustomobject]@{
        Name = $_.name
        Status = $_.properties.status
        HealthChecks = ($_.properties.sessionHostHealthCheckResults | ConvertTo-Json -Depth 10 -Compress)
    } } | Format-Table -Wrap
    if ($sessionHosts.Count -eq 0 -or @($sessionHosts | Where-Object { $_.properties.status -ne 'Available' }).Count) {
        throw 'Hosts are not yet all Available. Inspect the health results above; do not treat provisioning success as healthy AVD.'
    }
    Write-Host "Deployment verified. Access group: $($group.id). Test a fresh user sign-in to verify the FSLogix profile container."
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    $env:AVD_ADMIN_PASSWORD = $previousPassword
    $env:AVD_USER_GROUP_OBJECT_ID = $previousGroup
    $env:AVD_SERVICE_PRINCIPAL_OBJECT_ID = $previousPrincipal
    $script:graphToken = $null
}