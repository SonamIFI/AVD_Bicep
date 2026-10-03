param(
    [Parameter(Mandatory)][string]$StorageAccountName,
    [Parameter(Mandatory)][string]$StorageSuffix,
    [Parameter(Mandatory)][string]$FileShareName,
    [Parameter(Mandatory)][guid]$UserGroupObjectId,
    [string]$InitializeShare = 'false',
    [string]$StorageKey
)

$ErrorActionPreference = 'Stop'

function Install-FSLogixIfMissing {
    if (Get-Service frxsvc -ErrorAction SilentlyContinue) { return }

    $workingDirectory = Join-Path $env:TEMP "fslogix-$([guid]::NewGuid().ToString('N'))"
    $logDirectory = Join-Path $env:ProgramData 'FSLogix\Deployment'
    New-Item -ItemType Directory -Path $workingDirectory, $logDirectory -Force | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $archivePath = Join-Path $workingDirectory 'FSLogix.zip'
        Invoke-WebRequest -Uri 'https://aka.ms/fslogix_download' -OutFile $archivePath -UseBasicParsing -TimeoutSec 300
        Expand-Archive -Path $archivePath -DestinationPath $workingDirectory -Force
        $installers = @(Get-ChildItem $workingDirectory -Filter FSLogixAppsSetup.exe -Recurse |
            Where-Object { $_.FullName -match '[\\/]x64[\\/]Release[\\/]FSLogixAppsSetup\.exe$' })
        if ($installers.Count -ne 1) { throw 'The FSLogix archive did not contain exactly one x64 Apps installer.' }
        $installerPath = $installers[0].FullName
        $signature = Get-AuthenticodeSignature $installerPath
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
            throw 'The FSLogix installer does not have a valid Microsoft signature.'
        }
        $logPath = Join-Path $logDirectory 'install.log'
        $installer = Start-Process -FilePath $installerPath -ArgumentList @(
            '/install', '/quiet', '/norestart', '/log', "`"$logPath`""
        ) -Wait -PassThru
        if ($installer.ExitCode -notin 0, 3010) {
            throw "FSLogix installation failed with exit code $($installer.ExitCode). See $logPath."
        }
        if (-not (Get-Service frxsvc -ErrorAction SilentlyContinue)) {
            throw "FSLogix installation finished but frxsvc is missing. See $logPath."
        }
        Write-Output 'FSLogix installed successfully; the deployment orchestrator must reboot the host.'
    }
    finally {
        Remove-Item $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$windowsVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ([int]$windowsVersion.CurrentBuild -lt 26100 -or
    ([int]$windowsVersion.CurrentBuild -in 26100, 26200 -and [int]$windowsVersion.UBR -lt 8116)) {
    throw 'Cloud-only Azure Files requires a patched Windows 11 image (24H2/25H2 build .8116 or later).'
}
Install-FSLogixIfMissing

$fileHost = "$StorageAccountName.file.$StorageSuffix"
$addresses = Resolve-DnsName $fileHost -Type A -ErrorAction Stop
if (-not ($addresses | Where-Object { $_.IPAddress -like '10.10.4.*' })) {
    throw 'The file endpoint did not resolve to the private endpoint subnet.'
}
if (-not (Test-NetConnection $fileHost -Port 445 -InformationLevel Quiet)) {
    throw 'The Azure Files private endpoint is unreachable on TCP 445.'
}
$sharePath = "\\$fileHost\$FileShareName"

if ($InitializeShare -eq 'true') {
    if (-not $StorageKey) { throw 'A protected storage key is required to initialize profile ACLs.' }
    $credential = [pscredential]::new("localhost\$StorageAccountName", (ConvertTo-SecureString $StorageKey -AsPlainText -Force))
    try {
        New-PSDrive -Name Profiles -PSProvider FileSystem -Root $sharePath -Credential $credential | Out-Null
        $groupBytes = $UserGroupObjectId.ToByteArray()
        $sidParts = for ($offset = 0; $offset -lt 16; $offset += 4) {
            [BitConverter]::ToUInt32($groupBytes, $offset)
        }
        $groupSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-12-1-$($sidParts -join '-')")
        $acl = Get-Acl 'Profiles:\'
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            [void]$acl.RemoveAccessRuleSpecific($rule)
        }
        $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        foreach ($adminSid in 'S-1-5-18', 'S-1-5-32-544') {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                [System.Security.Principal.SecurityIdentifier]::new($adminSid), 'FullControl', $inheritance, 'None', $allow))
        }
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new('S-1-3-0'), 'Modify', $inheritance, 'InheritOnly', $allow))
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $groupSid, 'ReadAndExecute, Write', 'None', 'None', $allow))
        Set-Acl 'Profiles:\' $acl
    }
    finally {
        Remove-PSDrive Profiles -ErrorAction SilentlyContinue
        $StorageKey = $null
        $credential = $null
    }
}

$profileRegistry = 'HKLM:\SOFTWARE\FSLogix\Profiles'
New-Item $profileRegistry -Force | Out-Null
New-ItemProperty $profileRegistry -Name VHDLocations -PropertyType MultiString -Value @($sharePath) -Force | Out-Null
New-ItemProperty $profileRegistry -Name VolumeType -PropertyType String -Value VHDX -Force | Out-Null
New-ItemProperty $profileRegistry -Name Enabled -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty $profileRegistry -Name PreventLoginWithFailure -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty $profileRegistry -Name PreventLoginWithTempProfile -PropertyType DWord -Value 1 -Force | Out-Null

$kerberosRegistry = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'
New-Item $kerberosRegistry -Force | Out-Null
New-ItemProperty $kerberosRegistry -Name CloudKerberosTicketRetrievalEnabled -PropertyType DWord -Value 1 -Force | Out-Null
$accountRegistry = 'HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount'
New-Item $accountRegistry -Force | Out-Null
New-ItemProperty $accountRegistry -Name LoadCredKeyFromProfile -PropertyType DWord -Value 1 -Force | Out-Null
Start-Service iphlpsvc
Start-Service WinHttpAutoProxySvc
Set-Service frxsvc -StartupType Automatic
Start-Service frxsvc
Write-Output 'FSLogix configured; private DNS and SMB connectivity verified.'