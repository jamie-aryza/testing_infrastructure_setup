<#
.SYNOPSIS
    Applies a SQL Server configuration baseline (captured by Inventory-SqlServer.ps1)
    to a target dev/test SQL Server instance.

.DESCRIPTION
    Reads JSON files produced by Inventory-SqlServer.ps1 and brings the target instance
    in line with the baseline. Supports -WhatIf for dry-run.

    What it applies:
      - sp_configure values (excluding Database Mail XPs - handled separately)
      - Trace flags (enables baseline flags missing on target; warns on extra flags)
      - Database Mail (mode-controlled - see -DbMailMode)

    What it deliberately does NOT apply:
      - Max server memory      -> depends on target host RAM, not source
      - MAXDOP                 -> depends on target host cores, not source
      - tempdb file layout     -> file sizes should reflect target host disks
      - Logins, server roles   -> different security boundary in dev/test
      - Linked servers         -> different network reachability
      - Endpoints              -> mostly clustering/mirroring concerns
      - Databases / data       -> restore from anonymised backups, not config sync

    For the skipped items the script prints guidance at the end.

.PARAMETER SqlInstance
    Target SQL Server (dev/test). Refuses to run if this matches the source recorded
    in the baseline manifest.

.PARAMETER BaselinePath
    Folder containing the JSON files from Inventory-SqlServer.ps1.

.PARAMETER DbMailMode
    Disable          - sp_configure 'Database Mail XPs' = 0. Existing accounts/profiles untouched but inert. (Default)
    RedirectToLocal  - Recreate accounts/profiles from baseline but rewrite SMTP host/port to a local catcher.
    Match            - Mirror baseline exactly (DANGEROUS - could send real email from dev/test).

.PARAMETER LocalSmtpHost / LocalSmtpPort
    Used only with -DbMailMode RedirectToLocal. Defaults: localhost:25 (smtp4dev / MailHog default).

.PARAMETER SkipSpConfigure / SkipTraceFlags / SkipDbMail
    Skip individual sections.

.PARAMETER SqlCredential
    Optional. PSCredential for SQL auth. Omit for Windows auth.

.PARAMETER TrustServerCertificate
    Skip TLS certificate chain validation. Required for local SQL Server instances using
    self-signed certificates (default for SQL Server Developer / Express). Connection is
    still encrypted - just not validated.

.EXAMPLE
    # Dry-run against dev
    .\Apply-SqlBaseline.ps1 -SqlInstance dev-sql-01 -BaselinePath ..\..\infrastructure-baseline\prod-primary -WhatIf

.EXAMPLE
    # Real apply, DBMail redirected to a local smtp4dev container
    .\Apply-SqlBaseline.ps1 -SqlInstance dev-sql-01 `
        -BaselinePath ..\..\infrastructure-baseline\prod-primary `
        -DbMailMode RedirectToLocal -LocalSmtpHost localhost -LocalSmtpPort 25
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$SqlInstance,

    [Parameter(Mandatory)]
    [string]$BaselinePath,

    [ValidateSet('Disable', 'RedirectToLocal', 'Match')]
    [string]$DbMailMode = 'Disable',

    [string]$LocalSmtpHost = 'localhost',
    [int]$LocalSmtpPort   = 25,

    [switch]$SkipSpConfigure,
    [switch]$SkipTraceFlags,
    [switch]$SkipDbMail,

    [System.Management.Automation.PSCredential]$SqlCredential,

    [switch]$TrustServerCertificate
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name dbatools)) {
    Write-Host "Installing dbatools (current user scope)..." -ForegroundColor Yellow
    Install-Module dbatools -Scope CurrentUser -Force
}
Import-Module dbatools

if (-not (Test-Path $BaselinePath)) {
    Write-Error "Baseline path not found: $BaselinePath"
    exit 1
}

function Read-Baseline {
    param([string]$Name)
    $path = Join-Path $BaselinePath "$Name.json"
    if (-not (Test-Path $path)) {
        Write-Warning "Baseline file missing: $path - skipping that section"
        return $null
    }
    Get-Content $path -Raw | ConvertFrom-Json
}

# ---------- Safety: refuse to run against the baseline source ----------
$manifest = Read-Baseline '_manifest'
if ($manifest -and $manifest.SqlInstance -eq $SqlInstance) {
    Write-Error "Refusing to apply baseline to its own source ($SqlInstance). This script is for dev/test targets."
    exit 1
}

$connect = @{ SqlInstance = $SqlInstance }
if ($SqlCredential)          { $connect.SqlCredential          = $SqlCredential }
if ($TrustServerCertificate) { $connect.TrustServerCertificate = $true }

try {
    $target = Connect-DbaInstance @connect
    Write-Host "Target: $($target.Name) - $($target.VersionString) ($($target.Edition))" -ForegroundColor Green
    if ($manifest) {
        Write-Host "Baseline source: $($manifest.SqlInstance) (captured $($manifest.CapturedAtUtc) by $($manifest.CapturedBy))" -ForegroundColor Gray
    }
}
catch {
    Write-Error "Could not connect to $SqlInstance - $($_.Exception.Message)"
    exit 1
}

# Use the already-connected instance for all downstream dbatools calls.
# Avoids splatting params (like TrustServerCertificate) to cmdlets that don't accept them.
$connect = @{ SqlInstance = $target }

$changes  = New-Object System.Collections.Generic.List[string]
$skips    = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

# ---------- sp_configure ----------
if (-not $SkipSpConfigure) {
    Write-Host "`n[sp_configure]" -ForegroundColor Cyan
    $baseline = Read-Baseline 'sql-sp-configure'
    if ($baseline) {
        $current = Get-DbaSpConfigure @connect
        $currentByName = @{}
        foreach ($c in $current) { $currentByName[$c.ConfigName] = $c }

        # Skip these - they are hardware/host-specific or handled in their own section
        $skipNames = @(
            'MaxServerMemory', 'MinServerMemory', 'MaxDegreeOfParallelism',
            'CostThresholdForParallelism', 'DatabaseMailEnabled'
        )

        foreach ($b in $baseline) {
            if ($skipNames -contains $b.ConfigName) {
                $skips.Add("sp_configure: $($b.DisplayName) intentionally skipped (host- or section-specific)")
                continue
            }
            $cur = $currentByName[$b.ConfigName]
            if (-not $cur) {
                $warnings.Add("sp_configure: $($b.DisplayName) exists in baseline but not on target (different SQL version?) - skipping")
                continue
            }
            if ($cur.RunningValue -ne $b.RunningValue) {
                $msg = "sp_configure: '$($b.DisplayName)' $($cur.RunningValue) -> $($b.RunningValue)"
                if ($PSCmdlet.ShouldProcess($SqlInstance, $msg)) {
                    Set-DbaSpConfigure @connect -Name $b.ConfigName -Value $b.RunningValue | Out-Null
                    $changes.Add($msg)
                }
            }
        }
    }
}
else { $skips.Add("sp_configure: skipped via -SkipSpConfigure") }

# ---------- Trace flags ----------
if (-not $SkipTraceFlags) {
    Write-Host "`n[Trace flags]" -ForegroundColor Cyan
    $baseline = Read-Baseline 'sql-trace-flags'
    if ($baseline) {
        $current = Get-DbaTraceFlag @connect
        $currentFlags  = @($current | Where-Object Global -eq $true | Select-Object -ExpandProperty TraceFlag)
        $baselineFlags = @($baseline | Where-Object Global -eq $true | Select-Object -ExpandProperty TraceFlag)

        $missing = $baselineFlags | Where-Object { $_ -notin $currentFlags }
        $extra   = $currentFlags  | Where-Object { $_ -notin $baselineFlags }

        foreach ($flag in $missing) {
            $msg = "Enable global trace flag $flag"
            if ($PSCmdlet.ShouldProcess($SqlInstance, $msg)) {
                Enable-DbaTraceFlag @connect -TraceFlag $flag | Out-Null
                $changes.Add($msg)
            }
        }
        foreach ($flag in $extra) {
            $warnings.Add("Trace flag $flag is enabled on target but NOT in baseline - leaving alone (review manually)")
        }
    }
}
else { $skips.Add("Trace flags: skipped via -SkipTraceFlags") }

# ---------- Database Mail ----------
if (-not $SkipDbMail) {
    Write-Host "`n[Database Mail - mode: $DbMailMode]" -ForegroundColor Cyan
    $baseline = Read-Baseline 'dbmail'

    switch ($DbMailMode) {
        'Disable' {
            $current = Get-DbaSpConfigure @connect -Name 'DatabaseMailEnabled'
            if ($current.RunningValue -ne 0) {
                $msg = "Disable Database Mail XPs (set to 0)"
                if ($PSCmdlet.ShouldProcess($SqlInstance, $msg)) {
                    Set-DbaSpConfigure @connect -Name 'DatabaseMailEnabled' -Value 0 | Out-Null
                    $changes.Add($msg)
                }
            }
            $skips.Add("DBMail: existing accounts/profiles left in place but inert (DBMail XPs = 0)")
        }

        'RedirectToLocal' {
            if (-not $baseline) {
                $warnings.Add("DBMail: RedirectToLocal requested but no dbmail.json in baseline - nothing to recreate")
            }
            else {
                # Enable DBMail XPs
                $current = Get-DbaSpConfigure @connect -Name 'DatabaseMailEnabled'
                if ($current.RunningValue -ne 1) {
                    $msg = "Enable Database Mail XPs"
                    if ($PSCmdlet.ShouldProcess($SqlInstance, $msg)) {
                        Set-DbaSpConfigure @connect -Name 'DatabaseMailEnabled' -Value 1 | Out-Null
                        $changes.Add($msg)
                    }
                }

                # Recreate accounts pointed at the local catcher
                foreach ($acct in $baseline.Accounts) {
                    $msg = "Recreate DBMail account '$($acct.Name)' -> $LocalSmtpHost`:$LocalSmtpPort"
                    if ($PSCmdlet.ShouldProcess($SqlInstance, $msg)) {
                        # Drop + recreate is simplest and idempotent
                        $sql = @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = N'$($acct.Name)')
    EXEC msdb.dbo.sysmail_delete_account_sp @account_name = N'$($acct.Name)';

EXEC msdb.dbo.sysmail_add_account_sp
    @account_name        = N'$($acct.Name)',
    @email_address       = N'$($acct.EmailAddress)',
    @display_name        = N'$($acct.DisplayName) (DEV - captured locally)',
    @mailserver_name     = N'$LocalSmtpHost',
    @port                = $LocalSmtpPort,
    @enable_ssl          = 0;
"@
                        Invoke-DbaQuery @connect -Database msdb -Query $sql | Out-Null
                        $changes.Add($msg)
                    }
                }

                # Recreate profiles + bind to recreated accounts (priority 1, in order)
                foreach ($prof in $baseline.Profiles) {
                    $msg = "Recreate DBMail profile '$($prof.Name)'"
                    if ($PSCmdlet.ShouldProcess($SqlInstance, $msg)) {
                        $sql = @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = N'$($prof.Name)')
BEGIN
    EXEC msdb.dbo.sysmail_delete_profile_sp @profile_name = N'$($prof.Name)';
END

EXEC msdb.dbo.sysmail_add_profile_sp
    @profile_name = N'$($prof.Name)',
    @description  = N'$($prof.Description) (DEV - local catcher)';
"@
                        Invoke-DbaQuery @connect -Database msdb -Query $sql | Out-Null

                        # Bind first account from baseline to this profile (sufficient for most setups)
                        if ($baseline.Accounts -and $baseline.Accounts.Count -gt 0) {
                            $firstAcct = $baseline.Accounts[0].Name
                            $bindSql = @"
EXEC msdb.dbo.sysmail_add_profileaccount_sp
    @profile_name  = N'$($prof.Name)',
    @account_name  = N'$firstAcct',
    @sequence_number = 1;
"@
                            Invoke-DbaQuery @connect -Database msdb -Query $bindSql | Out-Null
                        }
                        $changes.Add($msg)
                    }
                }
            }
        }

        'Match' {
            $warnings.Add("DBMail: Mode 'Match' would mirror baseline SMTP servers exactly. NOT IMPLEMENTED - too dangerous to script silently. Apply manually if you really need it.")
        }
    }
}
else { $skips.Add("DBMail: skipped via -SkipDbMail") }

# ---------- Summary ----------
Write-Host "`n========== Summary ==========" -ForegroundColor Magenta

if ($WhatIfPreference) {
    Write-Host "DRY RUN - no changes applied. Re-run without -WhatIf to apply." -ForegroundColor Yellow
}

if ($changes.Count -gt 0) {
    Write-Host "`nChanges ($($changes.Count)):" -ForegroundColor Green
    $changes | ForEach-Object { Write-Host "  + $_" }
}
else {
    Write-Host "`nNo changes were needed - target already matches baseline." -ForegroundColor Green
}

if ($warnings.Count -gt 0) {
    Write-Host "`nWarnings ($($warnings.Count)):" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "  ! $_" }
}

if ($skips.Count -gt 0) {
    Write-Host "`nSkipped:" -ForegroundColor Gray
    $skips | ForEach-Object { Write-Host "  - $_" }
}

Write-Host "`nManual follow-ups (this script intentionally does not touch these):" -ForegroundColor Cyan
Write-Host "  * max server memory  -> use Test-DbaMaxMemory + Set-DbaMaxMemory sized to the target box"
Write-Host "  * MAXDOP             -> use Test-DbaMaxDop  + Set-DbaMaxDop  sized to the target cores"
Write-Host "  * tempdb files       -> use Set-DbaTempdbConfig with file count from baseline, sizes scaled to target disks"
Write-Host "  * Logins / roles     -> restore from a security baseline backup or recreate per env"
Write-Host "  * Databases          -> restore from an anonymised backup; do not copy prod data"
