$ErrorActionPreference = 'Stop'
$parseTokens = $null
$parseErrors = $null
$setupPath = Join-Path $PSScriptRoot 'configure-fslogix.ps1'
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$installFunction = $setupAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-FSLogixIfMissing'
}, $true)
if (-not $installFunction) { throw 'Installation function is missing.' }

function Test-InstallationCase {
    param(
        [string]$Name,
        [bool]$AlreadyInstalled = $false,
        [int]$ExitCode = 0,
        [string]$SignatureStatus = 'Valid',
        [string]$SignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US',
        [int]$InstallerCount = 1,
        [bool]$DownloadFails = $false,
        [bool]$ServiceAppears = $true,
        [bool]$ExpectFailure = $false
    )
    $state = @{
        Installed = $AlreadyInstalled
        Downloads = 0
        Executions = 0
        Cleaned = $false
        ErrorMessage = $null
    }
    function Get-Service { if ($state.Installed) { [pscustomobject]@{ Name = 'frxsvc' } } }
    function New-Item { }
    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
        $state.Downloads++
        if ($Uri -ne 'https://aka.ms/fslogix_download') { throw 'Unexpected download source.' }
        if ($DownloadFails) { throw 'Simulated network failure.' }
    }
    function Expand-Archive { }
    function Get-ChildItem {
        for ($installerIndex = 0; $installerIndex -lt $InstallerCount; $installerIndex++) {
            [pscustomobject]@{ FullName = "C:\mock\$installerIndex\x64\Release\FSLogixAppsSetup.exe" }
        }
    }
    function Get-AuthenticodeSignature {
        [pscustomobject]@{
            Status = $SignatureStatus
            SignerCertificate = [pscustomobject]@{ Subject = $SignerSubject }
        }
    }
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
        $state.Executions++
        if (-not $Wait -or -not $PassThru -or '/quiet' -notin $ArgumentList -or '/norestart' -notin $ArgumentList) {
            throw 'Installer was not silent, synchronous, and reboot-suppressed.'
        }
        $state.Installed = $ServiceAppears
        [pscustomobject]@{ ExitCode = $ExitCode }
    }
    function Remove-Item { $state.Cleaned = $true }
    Invoke-Expression $installFunction.Extent.Text
    try { Install-FSLogixIfMissing | Out-Null }
    catch { $state.ErrorMessage = $_.Exception.Message }
    if ($ExpectFailure -ne [bool]$state.ErrorMessage) {
        throw "$Name failed: unexpected result '$($state.ErrorMessage)'."
    }
    if ($AlreadyInstalled) {
        if ($state.Downloads -ne 0 -or $state.Executions -ne 0) { throw "$Name did not skip installation." }
    } else {
        if ($state.Downloads -ne 1 -or -not $state.Cleaned) { throw "$Name did not download once and clean up." }
    }
    if (($SignatureStatus -ne 'Valid' -or $SignerSubject -notmatch 'O=Microsoft Corporation' -or
        $InstallerCount -ne 1 -or $DownloadFails) -and $state.Executions -ne 0) {
        throw "$Name executed an installer that should have been rejected."
    }
    Write-Output "$Name`: PASS"
}

Test-InstallationCase -Name 'Preinstalled host' -AlreadyInstalled $true
Test-InstallationCase -Name 'Missing FSLogix installed'
Test-InstallationCase -Name 'Reboot-required exit accepted' -ExitCode 3010
Test-InstallationCase -Name 'Installer failure propagated' -ExitCode 1603 -ExpectFailure $true
Test-InstallationCase -Name 'Missing service rejected' -ServiceAppears $false -ExpectFailure $true
Test-InstallationCase -Name 'Invalid signature rejected' -SignatureStatus NotSigned -ExpectFailure $true
Test-InstallationCase -Name 'Wrong publisher rejected' -SignerSubject 'CN=Other, O=Other, C=US' -ExpectFailure $true
Test-InstallationCase -Name 'Ambiguous archive rejected' -InstallerCount 2 -ExpectFailure $true
Test-InstallationCase -Name 'Download failure propagated' -DownloadFails $true -ExpectFailure $true

foreach ($scriptName in 'deploy.ps1', 'Test-FSLogixInstallation.ps1') {
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $scriptName), [ref]$parseTokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
Write-Output 'PowerShell syntax: PASS'