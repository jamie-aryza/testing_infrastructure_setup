<#
.SYNOPSIS
    Captures a SQL Server instance + host configuration baseline as JSON files,
    suitable for committing to Git so dev/test environments can be kept in sync with prod.

.DESCRIPTION
    Uses dbatools to extract:
      - Host hardware (CPU, RAM, OS, disks) so you can pick a matching EC2 instance type
      - SQL Server version, edition, build, collation
      - sp_configure values, trace flags, MAXDOP, memory, cost threshold for parallelism
      - tempdb file layout (count, size, growth, paths)
      - Database Mail accounts, profiles, and enable flag (so dev/test can match-then-disable)
      - Database list with recovery model + compatibility level (metadata only - no data)
      - Logins, server roles, linked servers, endpoints

    Output is one JSON file per concern under -OutputPath. Re-run safely; files are overwritten.
    Commit the output folder to Git so config drift between runs is a visible diff.

.PARAMETER SqlInstance
    The SQL Server to inventory. Examples: "prod-sql-01", "prod-sql-01\INSTANCE", "prod-sql-01,1433".

.PARAMETER OutputPath
    Folder to write JSON files into. Created if missing. Defaults to ./infrastructure-baseline/<server>.

.PARAMETER SqlCredential
    Optional. PSCredential for SQL auth. If omitted, uses Windows auth from the calling user.

.PARAMETER TrustServerCertificate
    Skip TLS certificate chain validation. Required for local SQL Server instances using
    self-signed certificates (default for SQL Server Developer / Express). Connection is
    still encrypted - just not validated. Leave off when targeting prod with a real cert.

.PARAMETER Environment
    Optional. When supplied (Dev or Test), writes/updates the matching PostInstall.<Env>.Config.psd1
    in scripts/sql-install/ with the BaselinePath and DbMailMode derived from this run.
    GhaDeployLoginName and TargetDatabase are preserved if the file already exists.

.EXAMPLE
    .\Inventory-SqlServer.ps1 -SqlInstance prod-sql-01 -OutputPath ..\..\infrastructure-baseline\prod-primary

.EXAMPLE
    # Local SQL Server with self-signed cert
    .\Inventory-SqlServer.ps1 -SqlInstance "DESKTOP-QSU8PTS\LIVE" -TrustServerCertificate

.EXAMPLE
    $cred = Get-Credential
    .\Inventory-SqlServer.ps1 -SqlInstance prod-sql-01 -SqlCredential $cred
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SqlInstance,

    [string]$OutputPath,

    [System.Management.Automation.PSCredential]$SqlCredential,

    [switch]$TrustServerCertificate,

    [ValidateSet('Live', 'Test')]
    [string]$Environment
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name dbatools)) {
    Write-Host "Installing dbatools (current user scope)..." -ForegroundColor Yellow
    Install-Module dbatools -Scope CurrentUser -Force
}
Import-Module dbatools

if (-not $OutputPath) {
    $safeName = $SqlInstance -replace '[\\,:]', '_'
    $OutputPath = Join-Path -Path (Get-Location) -ChildPath "infrastructure-baseline\$safeName"
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$connectParams = @{ SqlInstance = $SqlInstance }
if ($SqlCredential)          { $connectParams.SqlCredential          = $SqlCredential }
if ($TrustServerCertificate) { $connectParams.TrustServerCertificate = $true }

# Sanity check the connection up front
try {
    $instance = Connect-DbaInstance @connectParams
    Write-Host "Connected to $($instance.Name) - $($instance.VersionString) ($($instance.Edition))" -ForegroundColor Green
}
catch {
    Write-Error "Could not connect to $SqlInstance - $($_.Exception.Message)"
    exit 1
}

# For all downstream dbatools calls, pass the already-connected instance object.
# This carries the established connection (incl. TrustServerCertificate) so we don't
# have to re-splat parameters that not every cmdlet accepts.
$dba = @{ SqlInstance = $instance }

function Save-Json {
    param([string]$Name, $Data)
    $path = Join-Path $OutputPath "$Name.json"
    $Data | ConvertTo-Json -Depth 8 | Out-File -FilePath $path -Encoding utf8
    Write-Host "  wrote $Name.json"
}

# Wraps a data-gathering scriptblock so a missing cmdlet (e.g. dbatools rename across versions)
# or a permissions error skips that section with a warning instead of killing the whole run.
function Invoke-Capture {
    param([string]$Name, [scriptblock]$Block)
    try {
        $data = & $Block
        Save-Json $Name $data
    }
    catch {
        Write-Warning "  SKIPPED $Name - $($_.Exception.Message)"
    }
}

Write-Host "`nGathering host details..." -ForegroundColor Cyan
try {
    $os       = Get-DbaOperatingSystem -ComputerName $instance.ComputerName -ErrorAction Stop
    $hw       = Get-DbaComputerSystem  -ComputerName $instance.ComputerName -ErrorAction Stop
    $disks    = Get-DbaDiskSpace       -ComputerName $instance.ComputerName -ErrorAction Stop

    Save-Json 'host-os' ($os | Select-Object Name, OSVersion, Architecture, ServicePack, LastBootTime, TimeZone)
    Save-Json 'host-hardware' ($hw | Select-Object Manufacturer, Model, Domain, NumberLogicalProcessors, NumberProcessors, TotalPhysicalMemory)
    Save-Json 'host-disks' ($disks | Select-Object Name, Label, SizeInGB, FreeInGB, BlockSize, FileSystem)
}
catch {
    Write-Warning "Host-level WMI calls failed (need admin on the host): $($_.Exception.Message)"
    Write-Warning "Skipping host-os / host-hardware / host-disks. SQL-level inventory will continue."
}

Write-Host "`nGathering SQL instance details..." -ForegroundColor Cyan

# Always succeeds - data is on the connected $instance object
Save-Json 'sql-version' ($instance | Select-Object @{n='Server';e={$_.Name}}, VersionString, Edition, ProductLevel, Collation, IsClustered, LoginMode, DefaultFile, DefaultLog, BackupDirectory)

Invoke-Capture 'sql-sp-configure' {
    Get-DbaSpConfigure @dba |
        Select-Object DisplayName, ConfigName, ConfiguredValue, RunningValue, DefaultValue, IsDynamic
}

Invoke-Capture 'sql-trace-flags' {
    Get-DbaTraceFlag @dba |
        Select-Object TraceFlag, Status, Global, Session
}

# Get-DbaMaxMemory / Get-DbaMaxDop may not exist in all dbatools versions.
# The underlying values are also captured in sql-sp-configure.json (MaxServerMemory,
# MaxDegreeOfParallelism), so a skip here is non-fatal.
Invoke-Capture 'sql-memory' {
    Get-DbaMaxMemory @dba |
        Select-Object Total, MaxValue, RecommendedValue
}

Invoke-Capture 'sql-maxdop' {
    Get-DbaMaxDop @dba |
        Select-Object Database, CurrentInstanceMaxDop, RecommendedMaxDop, NumaNodes, NumberOfCores
}

Invoke-Capture 'sql-tempdb' {
    Get-DbaTempdbConfig @dba
}

Write-Host "`nGathering Database Mail config..." -ForegroundColor Cyan
Invoke-Capture 'dbmail' {
    $cfg = Get-DbaSpConfigure @dba -Name 'DatabaseMailEnabled'
    $accts = Get-DbaDbMailAccount @dba |
        Select-Object Name, EmailAddress, DisplayName, MailServers, ReplyToAddress
    $profs = Get-DbaDbMailProfile @dba |
        Select-Object Name, Description, ForceDeleteForActiveProfiles
    @{
        Enabled  = [bool]$cfg.RunningValue
        Accounts = $accts
        Profiles = $profs
    }
}

Write-Host "`nGathering databases (metadata only)..." -ForegroundColor Cyan
Invoke-Capture 'databases' {
    Get-DbaDatabase @dba -ExcludeSystem |
        Select-Object Name, RecoveryModel, Compatibility, Collation, Owner, Status, SizeMB, LogSizeMB, CreateDate
}

Write-Host "`nGathering logins / roles / linked servers..." -ForegroundColor Cyan
Invoke-Capture 'logins' {
    Get-DbaLogin @dba -ExcludeSystemLogin |
        Select-Object Name, LoginType, IsDisabled, IsLocked, IsPasswordPolicyEnforced, IsPasswordExpirationEnabled, DefaultDatabase, Language
}

Invoke-Capture 'server-role-members' {
    Get-DbaServerRoleMember @dba |
        Select-Object Role, Login
}

Invoke-Capture 'linked-servers' {
    Get-DbaLinkedServer @dba |
        Select-Object Name, ProductName, DataSource, ProviderName, IsDataAccessEnabled, IsRpcEnabled
}

Invoke-Capture 'endpoints' {
    Get-DbaEndpoint @dba |
        Select-Object Name, EndpointType, Protocol, EndpointState, IsAdminEndpoint
}

# Write a manifest with run details so diffs across runs are clearly attributable
$manifest = [ordered]@{
    SqlInstance      = $SqlInstance
    CapturedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
    CapturedBy       = "$env:USERDOMAIN\$env:USERNAME"
    DbatoolsVersion  = (Get-Module dbatools).Version.ToString()
    OutputPath       = (Resolve-Path $OutputPath).Path
}
Save-Json '_manifest' $manifest

Write-Host "`nDone. Output: $OutputPath" -ForegroundColor Green
Write-Host "Suggested next step: " -NoNewline
Write-Host "git add $OutputPath && git diff --staged" -ForegroundColor Yellow

# Update the per-environment PostInstall config file if -Environment was supplied
if ($Environment) {
    $configDir     = Join-Path $PSScriptRoot '..\sql-install'
    $configFile    = Join-Path $configDir "PostInstall.$Environment.Config.psd1"
    $resolvedOutput = (Resolve-Path $OutputPath).Path

    # Derive BaselinePath relative to the repo root (two levels up from scripts/inventory/)
    $repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $relativePath = $resolvedOutput.Substring($repoRoot.Length).TrimStart('\','/')

    # Derive DbMailMode from captured dbmail.json
    $dbMailPath = Join-Path $resolvedOutput 'dbmail.json'
    $mailMode   = 'Disable'
    if (Test-Path $dbMailPath) {
        $dbMailData = Get-Content $dbMailPath -Raw | ConvertFrom-Json
        if ($dbMailData.Enabled -eq $true) { $mailMode = 'RedirectToLocal' }
    }

    # Preserve user-editable fields if the config file already exists
    $loginName     = 'gha_deploy'
    $targetDb      = ''
    $smtpHost      = 'localhost'
    $smtpPort      = 25
    if (Test-Path $configFile) {
        $existing  = Import-PowerShellDataFile -Path $configFile
        if ($existing.GhaDeployLoginName) { $loginName = [string]$existing.GhaDeployLoginName }
        if ($existing.TargetDatabase)     { $targetDb  = [string]$existing.TargetDatabase }
        if ($existing.LocalSmtpHost)      { $smtpHost  = [string]$existing.LocalSmtpHost }
        if ($existing.LocalSmtpPort)      { $smtpPort  = [int]$existing.LocalSmtpPort }
    }

    $configContent = @"
# Post-install configuration for the $Environment environment.
# Generated/updated by Inventory-SqlServer.ps1 -Environment $Environment.
# Review TargetDatabase and GhaDeployLoginName before running Invoke-PostInstall.ps1.
@{
    # Path to infrastructure-baseline/<server>/ produced by Inventory-SqlServer.ps1.
    # Updated automatically when Inventory-SqlServer.ps1 is run with -Environment $Environment.
    BaselinePath = '$relativePath'

    # DBMail handling in $($Environment.ToLower()).
    # Disable         - set DBMail XPs = 0 (safest default)
    # RedirectToLocal - recreate accounts/profiles pointing at a local SMTP catcher (smtp4dev / MailHog)
    DbMailMode    = '$mailMode'
    LocalSmtpHost = '$smtpHost'
    LocalSmtpPort = $smtpPort

    # Pipeline SQL login created on $($Environment.ToLower()) SQL Servers.
    GhaDeployLoginName = '$loginName'

    # Database to grant the pipeline login db_owner on. Leave empty to skip the grant.
    TargetDatabase = '$targetDb'
}
"@

    $configContent | Set-Content -Path $configFile -Encoding ASCII
    Write-Host "`nPostInstall.$Environment.Config.psd1 updated." -ForegroundColor Green
    Write-Host "  BaselinePath = $relativePath"
    Write-Host "  DbMailMode   = $mailMode"
    if (-not $targetDb) {
        Write-Host "  Review TargetDatabase in $configFile before running Invoke-PostInstall.ps1." -ForegroundColor Yellow
    }
}
