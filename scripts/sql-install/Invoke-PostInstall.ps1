<#
.SYNOPSIS
    Applies prod baseline and host-specific SQL Server configuration over WinRM HTTPS.

.DESCRIPTION
    Merges prod-sync (sp_configure, trace flags, DBMail) and host-specific tuning
    (memory, MAXDOP, tempdb, pipeline login) into a single script. All steps run
    remotely over WinRM HTTPS — consistent with Invoke-SqlInstall.ps1 and Invoke-HostPrep.ps1,
    and avoids the need for port 1433 to be open from the admin machine.

    Config is loaded from a per-environment PostInstall.<Env>.Config.psd1 file (auto-derived
    from -TerraformDir). All config values can be overridden by parameters.

    Use -Mode to run all steps, only prod-sync, or only host-specific.
    Use -Skip* switches for fine-grained exclusion within a mode.

.PARAMETER TerraformDir
    Terraform environment directory. Provides host IPs via outputs and drives the default
    config file name (terraform/dev -> PostInstall.Dev.Config.psd1).

.PARAMETER ConfigPath
    Path to SqlInstall.Config.psd1 (host list and Terraform output names).

.PARAMETER PostInstallConfig
    Path to the per-environment PostInstall config file. Defaults to PostInstall.<Env>.Config.psd1
    derived from TerraformDir, falling back to PostInstall.Config.psd1 if that doesn't exist.

.PARAMETER BaselinePath
    Override the BaselinePath in the config file. Path to infrastructure-baseline/<server>/.

.PARAMETER Credential
    Windows credential for WinRM HTTPS. Prompted if not supplied.

.PARAMETER UserName
    Account name when prompting for credentials. Default: .\sqlautomation.

.PARAMETER HostName
    Optional filter - run against named hosts only.

.PARAMETER Mode
    All          - run all steps (default)
    ProdSync     - sp_configure, trace flags, DBMail only
    HostSpecific - memory, MAXDOP, tempdb, login, linked server setup

.PARAMETER GhaDeployPassword
    SecureString password for the pipeline SQL login. Prompted if absent unless Mode = ProdSync.

.PARAMETER DbMailMode
    Override DbMailMode from config file. Disable | RedirectToLocal | Match.

.PARAMETER LocalSmtpHost / LocalSmtpPort
    Override SMTP catcher settings from config. Used with DbMailMode RedirectToLocal.

.PARAMETER LinkedServerPassword
    SecureString password for the linked server SQL login (ls_remote_query by default).
    Prompted if absent unless Mode = ProdSync or -SkipLinkedServer is set.

.PARAMETER SkipSpConfigure / SkipTraceFlags / SkipDbMail
    Skip individual prod-sync sections.

.PARAMETER SkipMemory / SkipMaxDop / SkipTempdb / SkipLogin / SkipLinkedServer
    Skip individual host-specific sections.

.EXAMPLE
    # Full apply for dev (reads PostInstall.Dev.Config.psd1 automatically)
    .\Invoke-PostInstall.ps1

.EXAMPLE
    # Dry run - shows what would change, makes nothing
    .\Invoke-PostInstall.ps1 -WhatIf

.EXAMPLE
    # Re-sync prod config only (no sizing or login changes)
    .\Invoke-PostInstall.ps1 -Mode ProdSync

.EXAMPLE
    # Test environment, single host
    .\Invoke-PostInstall.ps1 -TerraformDir terraform/test -HostName test-sql-live
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TerraformDir = 'terraform/dev',

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'SqlInstall.Config.psd1'),

    [string]$PostInstallConfig,

    [string]$BaselinePath,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$UserName = '.\sqlautomation',

    [string[]]$HostName,

    [ValidateSet('All', 'ProdSync', 'HostSpecific')]
    [string]$Mode = 'All',

    [System.Security.SecureString]$GhaDeployPassword,

    [System.Security.SecureString]$LinkedServerPassword,

    [ValidateSet('Disable', 'RedirectToLocal', 'Match')]
    [string]$DbMailMode,

    [string]$LocalSmtpHost,

    [int]$LocalSmtpPort,

    [switch]$SkipSpConfigure,
    [switch]$SkipTraceFlags,
    [switch]$SkipDbMail,
    [switch]$SkipMemory,
    [switch]$SkipMaxDop,
    [switch]$SkipTempdb,
    [switch]$SkipLogin,
    [switch]$SkipLinkedServer
)

$ErrorActionPreference = 'Stop'

# Default config file is the live role. Pass -PostInstallConfig explicitly for other roles
# (e.g. -PostInstallConfig .\PostInstall.Test.Config.psd1 when targeting the test SQL role).
if (-not $PostInstallConfig) {
    $PostInstallConfig = Join-Path $PSScriptRoot 'PostInstall.Live.Config.psd1'
}

if (-not (Test-Path $PostInstallConfig)) {
    throw "PostInstall config not found: $PostInstallConfig. Run Inventory-SqlServer.ps1 -Environment <Env> to generate it."
}
if (-not (Test-Path $ConfigPath)) {
    throw "Host config not found: $ConfigPath"
}

$piConfig   = Import-PowerShellDataFile -Path $PostInstallConfig
$hostConfig = Import-PowerShellDataFile -Path $ConfigPath

# Parameters override config file values
if (-not $BaselinePath) {
    $BaselinePath = [string]$piConfig.BaselinePath
}
if (-not $DbMailMode) {
    $DbMailMode = if ($piConfig.DbMailMode) { [string]$piConfig.DbMailMode } else { 'Disable' }
}
if (-not $LocalSmtpHost) {
    $LocalSmtpHost = if ($piConfig.LocalSmtpHost) { [string]$piConfig.LocalSmtpHost } else { 'localhost' }
}
if (-not $LocalSmtpPort) {
    $LocalSmtpPort = if ($piConfig.LocalSmtpPort) { [int]$piConfig.LocalSmtpPort } else { 25 }
}
$loginName      = if ($piConfig.GhaDeployLoginName) { [string]$piConfig.GhaDeployLoginName } else { 'gha_deploy' }
$targetDatabase = if ($piConfig.TargetDatabase)     { [string]$piConfig.TargetDatabase }     else { '' }
$lsName         = if ($piConfig.LinkedServerName)                  { [string]$piConfig.LinkedServerName }                  else { '' }
$lsLogin        = if ($piConfig.LinkedServerLogin)                 { [string]$piConfig.LinkedServerLogin }                 else { '' }
$lsRemoteOutput = if ($piConfig.LinkedServerRemoteTerraformOutput) { [string]$piConfig.LinkedServerRemoteTerraformOutput } else { '' }

if (-not (Test-Path $BaselinePath)) {
    throw "BaselinePath not found: $BaselinePath. Run Inventory-SqlServer.ps1 first."
}

function Read-BaselineJson {
    param([string]$Name)
    $p = Join-Path $BaselinePath "$Name.json"
    if (Test-Path $p) { Get-Content $p -Raw -Encoding UTF8 } else { '' }
}

$manifestJson   = Read-BaselineJson '_manifest'
$spConfigJson   = Read-BaselineJson 'sql-sp-configure'
$traceFlagsJson = Read-BaselineJson 'sql-trace-flags'
$dbMailJson     = Read-BaselineJson 'dbmail'
$tempdbJson     = Read-BaselineJson 'sql-tempdb'

function Get-TerraformOutputs {
    param([string]$Directory)
    $resolvedDirectory = (Resolve-Path $Directory).Path
    Write-Host "Reading Terraform outputs from $resolvedDirectory..." -ForegroundColor Cyan
    $json = & terraform -chdir="$resolvedDirectory" output -json
    if (-not $json) { throw "Terraform returned no output. Run terraform apply first." }
    $json | ConvertFrom-Json
}

$terraformOutputs = Get-TerraformOutputs -Directory $TerraformDir

$configuredHosts = @($hostConfig.Hosts)
if ($HostName) {
    $configuredHosts = @($configuredHosts | Where-Object { $_.Name -in $HostName })
    if (-not $configuredHosts) {
        throw "No configured hosts matched HostName: $($HostName -join ', ')"
    }
}

if (-not $Credential) {
    $pw = Read-Host "Enter password for $UserName" -AsSecureString
    $Credential = New-Object System.Management.Automation.PSCredential($UserName, $pw)
}

# Only prompt for the pipeline login password if the login step will actually run
$ghaPasswordPlain = ''
$needLogin = ($Mode -ne 'ProdSync') -and (-not $SkipLogin)
if ($needLogin) {
    if (-not $GhaDeployPassword) {
        $GhaDeployPassword = Read-Host "Enter password for $loginName SQL login" -AsSecureString
    }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($GhaDeployPassword)
    $ghaPasswordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

# Only prompt for the linked server password if linked server setup will actually run
$lsPasswordPlain = ''
$needLinkedServer = ($Mode -ne 'ProdSync') -and (-not $SkipLinkedServer) -and ($lsName -ne '')
if ($needLinkedServer) {
    if (-not $LinkedServerPassword) {
        $LinkedServerPassword = Read-Host "Enter password for '$lsLogin' linked server login" -AsSecureString
    }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($LinkedServerPassword)
    $lsPasswordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

$sessionOption   = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck -OpenTimeout 30000 -OperationTimeout 600000
$runProdSync     = $Mode -ne 'HostSpecific'
$runHostSpecific = $Mode -ne 'ProdSync'
$isWhatIf        = [bool]$WhatIfPreference

$remoteScript = {
    param(
        [bool]$RunProdSync,
        [bool]$RunHostSpecific,
        [bool]$IsWhatIf,
        [string]$ManifestJson,
        [string]$SpConfigJson,
        [string]$TraceFlagsJson,
        [string]$DbMailJson,
        [string]$TempdbJson,
        [string]$MailMode,
        [string]$SmtpHost,
        [int]$SmtpPort,
        [string]$LoginName,
        [string]$TargetDb,
        [string]$GhaPasswordPlain,
        [bool]$SkipSpConfigure,
        [bool]$SkipTraceFlags,
        [bool]$SkipDbMail,
        [bool]$SkipMemory,
        [bool]$SkipMaxDop,
        [bool]$SkipTempdb,
        [bool]$SkipLogin,
        [string]$LinkedServerName,
        [string]$LinkedServerLogin,
        [string]$LinkedServerRemoteIp,
        [string]$LsPasswordPlain,
        [bool]$SkipLinkedServer,
        [string]$BootstrapRoot
    )

    $ErrorActionPreference = 'Stop'
    $statusPath = Join-Path $BootstrapRoot 'PostInstall.status.json'

    $changes  = New-Object System.Collections.Generic.List[string]
    $skips    = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    if ($IsWhatIf) { Write-Host "DRY RUN - no changes will be applied." -ForegroundColor Yellow }

    # Verify SQL Server is running
    $svc = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        throw "MSSQLSERVER service is not running. Ensure the host rebooted after install if exit code 3010 was returned."
    }

    # Ensure NuGet provider is available (required by Install-Module, prompts interactively if missing)
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge '2.8.5.201' })) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }

    # Install dbatools if absent
    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        Write-Host "Installing dbatools (current user scope)..."
        Install-Module dbatools -Scope CurrentUser -Force
    }
    Import-Module dbatools

    $instance = Connect-DbaInstance -SqlInstance 'localhost' -TrustServerCertificate
    $dba = @{ SqlInstance = $instance }

    # Safety check: refuse to run against the baseline source server
    if ($ManifestJson) {
        $manifest = $ManifestJson | ConvertFrom-Json
        if ($manifest.SqlInstance -and (
            $manifest.SqlInstance -eq $env:COMPUTERNAME -or
            $manifest.SqlInstance -like "$($env:COMPUTERNAME)*"
        )) {
            throw "Refusing to run against the baseline source ($($env:COMPUTERNAME)). This script is for dev/test targets only."
        }
        Write-Host "Baseline source: $($manifest.SqlInstance) (captured $($manifest.CapturedAtUtc))" -ForegroundColor Gray
    }

    # ================================================================
    # PROD-SYNC STEPS
    # ================================================================
    if ($RunProdSync) {

        # sp_configure
        if (-not $SkipSpConfigure) {
            Write-Host "`n[sp_configure]" -ForegroundColor Cyan
            if ($SpConfigJson) {
                $baseline = $SpConfigJson | ConvertFrom-Json
                $current  = Get-DbaSpConfigure @dba
                $currentByName = @{}
                foreach ($c in $current) { $currentByName[$c.ConfigName] = $c }

                $skipNames = @(
                    'MaxServerMemory', 'MinServerMemory', 'MaxDegreeOfParallelism',
                    'CostThresholdForParallelism', 'DatabaseMailEnabled'
                )

                foreach ($b in $baseline) {
                    if ($skipNames -contains $b.ConfigName) {
                        $skips.Add("sp_configure '$($b.DisplayName)': skipped (host- or section-specific)")
                        continue
                    }
                    $cur = $currentByName[$b.ConfigName]
                    if (-not $cur) {
                        $warnings.Add("sp_configure '$($b.DisplayName)': in baseline but not on target (SQL version mismatch?) - skipping")
                        continue
                    }
                    if ($cur.RunningValue -ne $b.RunningValue) {
                        $msg = "sp_configure '$($b.DisplayName)': $($cur.RunningValue) -> $($b.RunningValue)"
                        if (-not $IsWhatIf) {
                            Set-DbaSpConfigure @dba -Name $b.ConfigName -Value $b.RunningValue | Out-Null
                        }
                        $changes.Add($msg)
                    }
                }
            } else {
                $warnings.Add("sql-sp-configure.json missing from baseline - sp_configure skipped")
            }
        } else { $skips.Add("sp_configure: skipped via -SkipSpConfigure") }

        # Trace flags
        if (-not $SkipTraceFlags) {
            Write-Host "`n[Trace flags]" -ForegroundColor Cyan
            if ($TraceFlagsJson) {
                $baseline      = $TraceFlagsJson | ConvertFrom-Json
                $current       = Get-DbaTraceFlag @dba
                $currentFlags  = @($current  | Where-Object Global -eq $true | Select-Object -ExpandProperty TraceFlag)
                $baselineFlags = @($baseline | Where-Object Global -eq $true | Select-Object -ExpandProperty TraceFlag)

                foreach ($flag in ($baselineFlags | Where-Object { $_ -notin $currentFlags })) {
                    $msg = "Enable global trace flag $flag"
                    if (-not $IsWhatIf) { Enable-DbaTraceFlag @dba -TraceFlag $flag | Out-Null }
                    $changes.Add($msg)
                }
                foreach ($flag in ($currentFlags | Where-Object { $_ -notin $baselineFlags })) {
                    $warnings.Add("Trace flag $flag enabled on target but not in baseline - leaving alone (review manually)")
                }
            } else {
                $warnings.Add("sql-trace-flags.json missing from baseline - trace flags skipped")
            }
        } else { $skips.Add("Trace flags: skipped via -SkipTraceFlags") }

        # DBMail
        if (-not $SkipDbMail) {
            Write-Host "`n[DBMail - mode: $MailMode]" -ForegroundColor Cyan
            $mailBaseline = if ($DbMailJson) { $DbMailJson | ConvertFrom-Json } else { $null }

            switch ($MailMode) {
                'Disable' {
                    $cur = Get-DbaSpConfigure @dba -Name 'DatabaseMailEnabled'
                    if ($cur.RunningValue -ne 0) {
                        $msg = "Disable Database Mail XPs (set to 0)"
                        if (-not $IsWhatIf) { Set-DbaSpConfigure @dba -Name 'DatabaseMailEnabled' -Value 0 | Out-Null }
                        $changes.Add($msg)
                    }
                    $skips.Add("DBMail: accounts/profiles left in place but inert (XPs = 0)")
                }
                'RedirectToLocal' {
                    if (-not $mailBaseline) {
                        $warnings.Add("DBMail: RedirectToLocal requested but dbmail.json missing - nothing to recreate")
                    } else {
                        $cur = Get-DbaSpConfigure @dba -Name 'DatabaseMailEnabled'
                        if ($cur.RunningValue -ne 1) {
                            $msg = "Enable Database Mail XPs"
                            if (-not $IsWhatIf) { Set-DbaSpConfigure @dba -Name 'DatabaseMailEnabled' -Value 1 | Out-Null }
                            $changes.Add($msg)
                        }
                        foreach ($acct in $mailBaseline.Accounts) {
                            $msg = "Recreate DBMail account '$($acct.Name)' -> ${SmtpHost}:$SmtpPort"
                            if (-not $IsWhatIf) {
                                $sql = @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = N'$($acct.Name)')
    EXEC msdb.dbo.sysmail_delete_account_sp @account_name = N'$($acct.Name)';
EXEC msdb.dbo.sysmail_add_account_sp
    @account_name    = N'$($acct.Name)',
    @email_address   = N'$($acct.EmailAddress)',
    @display_name    = N'$($acct.DisplayName) (DEV - local catcher)',
    @mailserver_name = N'$SmtpHost',
    @port            = $SmtpPort,
    @enable_ssl      = 0;
"@
                                Invoke-DbaQuery @dba -Database msdb -Query $sql | Out-Null
                            }
                            $changes.Add($msg)
                        }
                        foreach ($prof in $mailBaseline.Profiles) {
                            $msg = "Recreate DBMail profile '$($prof.Name)'"
                            if (-not $IsWhatIf) {
                                $sql = @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = N'$($prof.Name)')
    EXEC msdb.dbo.sysmail_delete_profile_sp @profile_name = N'$($prof.Name)';
EXEC msdb.dbo.sysmail_add_profile_sp
    @profile_name = N'$($prof.Name)',
    @description  = N'$($prof.Description) (DEV - local catcher)';
"@
                                Invoke-DbaQuery @dba -Database msdb -Query $sql | Out-Null
                                if ($mailBaseline.Accounts -and $mailBaseline.Accounts.Count -gt 0) {
                                    $firstAcct = $mailBaseline.Accounts[0].Name
                                    Invoke-DbaQuery @dba -Database msdb -Query @"
EXEC msdb.dbo.sysmail_add_profileaccount_sp
    @profile_name    = N'$($prof.Name)',
    @account_name    = N'$firstAcct',
    @sequence_number = 1;
"@ | Out-Null
                                }
                            }
                            $changes.Add($msg)
                        }
                    }
                }
                'Match' {
                    $warnings.Add("DBMail: Mode 'Match' not implemented - would mirror prod SMTP exactly. Apply manually if needed.")
                }
            }
        } else { $skips.Add("DBMail: skipped via -SkipDbMail") }
    }

    # ================================================================
    # HOST-SPECIFIC STEPS
    # ================================================================
    if ($RunHostSpecific) {

        # Memory
        if (-not $SkipMemory) {
            Write-Host "`n[Memory]" -ForegroundColor Cyan
            $memRec = Test-DbaMaxMemory @dba
            if ($memRec.MaxValue -ne $memRec.RecommendedValue) {
                $msg = "Max server memory: $($memRec.MaxValue) MB -> $($memRec.RecommendedValue) MB"
                if (-not $IsWhatIf) { Set-DbaMaxMemory @dba -Max $memRec.RecommendedValue | Out-Null }
                $changes.Add($msg)
            } else {
                Write-Host "  Already at recommended value ($($memRec.RecommendedValue) MB)"
            }
        } else { $skips.Add("Memory: skipped via -SkipMemory") }

        # MAXDOP
        if (-not $SkipMaxDop) {
            Write-Host "`n[MAXDOP]" -ForegroundColor Cyan
            $maxdopRows = @(Test-DbaMaxDop @dba)
            $serverRow  = $maxdopRows | Where-Object { -not $_.Database } | Select-Object -First 1
            if (-not $serverRow) { $serverRow = $maxdopRows | Select-Object -First 1 }
            if ($serverRow -and $serverRow.CurrentInstanceMaxDop -ne $serverRow.RecommendedMaxDop) {
                $msg = "MAXDOP: $($serverRow.CurrentInstanceMaxDop) -> $($serverRow.RecommendedMaxDop)"
                if (-not $IsWhatIf) { Set-DbaMaxDop @dba -MaxDop $serverRow.RecommendedMaxDop | Out-Null }
                $changes.Add($msg)
            } else {
                Write-Host "  Already at recommended value ($($serverRow.CurrentInstanceMaxDop))"
            }
        } else { $skips.Add("MAXDOP: skipped via -SkipMaxDop") }

        # tempdb
        if (-not $SkipTempdb) {
            Write-Host "`n[tempdb]" -ForegroundColor Cyan
            if ($TempdbJson) {
                $tempdbBaseline = $TempdbJson | ConvertFrom-Json
                $fileCount = [int]$tempdbBaseline.DataFileCount
                if ($fileCount -lt 1) { $fileCount = 2 }
                try {
                    $gDrive      = Get-PSDrive -Name G -ErrorAction Stop
                    $availableMB = [int]($gDrive.Free / 1MB)
                    # Scale to available G: disk. Cap per-file size to avoid over-provisioning a t3.micro.
                    # Long-term: remove size cap and scale fully to prod layout once hosts are production-sized.
                    $perFileMB = [Math]::Max(64, [Math]::Min([int]($availableMB * 0.8 / $fileCount), 512))
                    $logMB     = [Math]::Max(64, [Math]::Min([int]($availableMB * 0.1), 512))
                    $msg = "tempdb: $fileCount data files at $perFileMB MB, log at $logMB MB (file count from baseline; sizes scaled to G: disk)"
                    if (-not $IsWhatIf) {
                        Set-DbaTempdbConfig @dba -DataFileCount $fileCount -DataFileSizeMB $perFileMB -LogFileSizeMB $logMB | Out-Null
                    }
                    $changes.Add($msg)
                } catch {
                    $warnings.Add("G: drive error - tempdb skipped: $($_.Exception.Message)")
                }
            } else {
                $warnings.Add("sql-tempdb.json missing from baseline - tempdb skipped")
            }
        } else { $skips.Add("tempdb: skipped via -SkipTempdb") }

        # Pipeline login
        if (-not $SkipLogin) {
            Write-Host "`n[$LoginName login]" -ForegroundColor Cyan
            $existingLogin = Get-DbaLogin @dba -Login $LoginName
            if ($existingLogin) {
                $warnings.Add("Login '$LoginName' already exists - skipping creation")
            } else {
                $msg = "Create SQL login '$LoginName' (CHECK_POLICY=ON, CHECK_EXPIRATION=OFF)"
                if (-not $IsWhatIf) {
                    $secPwd = ConvertTo-SecureString $GhaPasswordPlain -AsPlainText -Force
                    New-DbaLogin @dba -Login $LoginName -SecurePassword $secPwd `
                        -PasswordPolicyEnforced -PasswordExpirationEnabled:$false | Out-Null
                }
                $changes.Add($msg)
            }
            if ($TargetDb) {
                $dbObj = Get-DbaDatabase @dba -Database $TargetDb -ErrorAction SilentlyContinue
                if (-not $dbObj) {
                    $warnings.Add("Database '$TargetDb' not found - db_owner grant skipped (create the database first)")
                } else {
                    $existingUser = Get-DbaDbUser @dba -Database $TargetDb | Where-Object { $_.Login -eq $LoginName }
                    if (-not $existingUser -and -not $IsWhatIf) {
                        New-DbaDbUser @dba -Database $TargetDb -Login $LoginName | Out-Null
                    }
                    $inRole = Get-DbaDbRoleMember @dba -Database $TargetDb -Role 'db_owner' | Where-Object { $_.UserName -eq $LoginName }
                    if ($inRole) {
                        $warnings.Add("'$LoginName' already has db_owner on '$TargetDb'")
                    } else {
                        $msg = "Grant '$LoginName' db_owner on '$TargetDb'"
                        if (-not $IsWhatIf) {
                            Add-DbaDbRoleMember @dba -Database $TargetDb -Role 'db_owner' -User $LoginName | Out-Null
                        }
                        $changes.Add($msg)
                    }
                }
            }
        } else { $skips.Add("Login: skipped via -SkipLogin") }

        # Linked server
        if (-not $SkipLinkedServer -and $LinkedServerName -and $LinkedServerRemoteIp) {
            Write-Host "`n[Linked server: $LinkedServerName -> $LinkedServerRemoteIp]" -ForegroundColor Cyan

            # Create the login on THIS host that the remote host will use to connect
            if ($LinkedServerLogin) {
                $existingLsLogin = Get-DbaLogin @dba -Login $LinkedServerLogin
                if ($existingLsLogin) {
                    $warnings.Add("Login '$LinkedServerLogin' already exists - skipping creation (linked server login)")
                } else {
                    $msg = "Create SQL login '$LinkedServerLogin' (for remote host to authenticate with this host)"
                    if (-not $IsWhatIf) {
                        $secPwd = ConvertTo-SecureString $LsPasswordPlain -AsPlainText -Force
                        New-DbaLogin @dba -Login $LinkedServerLogin -SecurePassword $secPwd `
                            -PasswordPolicyEnforced -PasswordExpirationEnabled:$false | Out-Null
                    }
                    $changes.Add($msg)
                }
            }

            # Create the linked server object pointing at the remote host
            $existingLs = Invoke-DbaQuery @dba -Query "SELECT name FROM sys.servers WHERE is_linked = 1 AND name = N'$LinkedServerName'"
            if ($existingLs) {
                $warnings.Add("Linked server '$LinkedServerName' already exists - skipping creation")
            } else {
                $msg = "Create linked server '$LinkedServerName' -> $LinkedServerRemoteIp,1433"
                if (-not $IsWhatIf) {
                    $createSql = @"
EXEC sp_addlinkedserver
    @server     = N'$LinkedServerName',
    @srvproduct = N'SQL Server',
    @datasrc    = N'$LinkedServerRemoteIp,1433';
EXEC sp_addlinkedsrvlogin
    @rmtsrvname  = N'$LinkedServerName',
    @useself     = N'false',
    @locallogin  = NULL,
    @rmtuser     = N'$LinkedServerLogin',
    @rmtpassword = N'$LsPasswordPlain';
EXEC sp_serveroption N'$LinkedServerName', N'rpc out', N'true';
"@
                    Invoke-DbaQuery @dba -Query $createSql | Out-Null
                }
                $changes.Add($msg)

                # Test the connection - non-fatal, remote host may not have the login yet
                if (-not $IsWhatIf) {
                    try {
                        Invoke-DbaQuery @dba -Query "EXEC sp_testlinkedserver N'$LinkedServerName'" -ErrorAction Stop | Out-Null
                        $changes.Add("Linked server '$LinkedServerName' connection test: OK")
                    } catch {
                        $warnings.Add("Linked server '$LinkedServerName' connection test failed (expected if remote host not yet configured): $($_.Exception.Message)")
                    }
                }
            }
        } elseif (-not $SkipLinkedServer -and -not $LinkedServerName) {
            $skips.Add("Linked server: no LinkedServerName configured in PostInstall config")
        } else {
            $skips.Add("Linked server: skipped via -SkipLinkedServer")
        }
    }

    # Summary
    Write-Host "`n========== Summary ==========" -ForegroundColor Magenta
    if ($IsWhatIf) { Write-Host "DRY RUN - no changes applied. Re-run without -WhatIf to apply." -ForegroundColor Yellow }

    if ($changes.Count -gt 0) {
        Write-Host "`nChanges ($($changes.Count)):" -ForegroundColor Green
        $changes | ForEach-Object { Write-Host "  + $_" }
    } else {
        Write-Host "`nNo changes needed - target already matches baseline." -ForegroundColor Green
    }
    if ($warnings.Count -gt 0) {
        Write-Host "`nWarnings ($($warnings.Count)):" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  ! $_" }
    }
    if ($skips.Count -gt 0) {
        Write-Host "`nSkipped:" -ForegroundColor Gray
        $skips | ForEach-Object { Write-Host "  - $_" }
    }

    $effectiveMode = if ($RunProdSync -and $RunHostSpecific) { 'All' } elseif ($RunProdSync) { 'ProdSync' } else { 'HostSpecific' }
    $status = [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        RanAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
        WhatIf       = $IsWhatIf
        Mode         = $effectiveMode
        Changes      = $changes.ToArray()
        Warnings     = $warnings.ToArray()
        Skips        = $skips.ToArray()
    }
    if (-not $IsWhatIf) {
        $status | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8
    }
    return $status
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($targetHost in $configuredHosts) {
    $outputName = [string]$targetHost.TerraformOutputName
    $address    = $terraformOutputs.$outputName.value
    if (-not $address) { throw "Missing Terraform output value for $outputName" }

    # Resolve remote host IP for linked server setup (different host in same environment)
    $lsRemoteIp = ''
    if ($lsRemoteOutput -and $terraformOutputs.$lsRemoteOutput) {
        $lsRemoteIp = [string]$terraformOutputs.$lsRemoteOutput.value
    }

    Write-Host "`nConnecting to $($targetHost.Name) at $address..." -ForegroundColor Cyan

    if ($PSCmdlet.ShouldProcess("$($targetHost.Name) ($address)", "Run post-install (Mode=$Mode)")) {
        try {
            $result = Invoke-Command `
                -ComputerName $address `
                -UseSSL `
                -Port 5986 `
                -Credential $Credential `
                -SessionOption $sessionOption `
                -ScriptBlock $remoteScript `
                -ArgumentList @(
                    $runProdSync,
                    $runHostSpecific,
                    $isWhatIf,
                    $manifestJson,
                    $spConfigJson,
                    $traceFlagsJson,
                    $dbMailJson,
                    $tempdbJson,
                    $DbMailMode,
                    $LocalSmtpHost,
                    [int]$LocalSmtpPort,
                    $loginName,
                    $targetDatabase,
                    $ghaPasswordPlain,
                    [bool]$SkipSpConfigure,
                    [bool]$SkipTraceFlags,
                    [bool]$SkipDbMail,
                    [bool]$SkipMemory,
                    [bool]$SkipMaxDop,
                    [bool]$SkipTempdb,
                    [bool]$SkipLogin,
                    $lsName,
                    $lsLogin,
                    $lsRemoteIp,
                    $lsPasswordPlain,
                    [bool]$SkipLinkedServer,
                    'C:\ProgramData\Amazon\HostPrep'
                )
        } catch {
            throw "Post-install failed for $($targetHost.Name) at $address. Error: $($_.Exception.Message)"
        }

        $results.Add([pscustomobject]@{
            Name    = $targetHost.Name
            Address = $address
            Result  = $result
        })
    }
}

Write-Host "`n========== Run Complete ==========" -ForegroundColor Magenta
foreach ($item in $results) {
    $r = $item.Result
    $tag = if ($r.WhatIf) { " [DRY RUN]" } else { "" }
    Write-Host "$($item.Name) -> $($item.Address)  [Mode: $($r.Mode)$tag]" -ForegroundColor Green
}
