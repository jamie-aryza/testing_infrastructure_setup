<#
.SYNOPSIS
    Drives SQL Server installation against dev SQL EC2 instances over WinRM HTTPS.

.DESCRIPTION
    Reads Terraform outputs for current host addresses, then for each host:
      - generates a pre-signed S3 URL for the SQL Server ISO (using local AWS credentials)
      - connects over WinRM HTTPS and runs the install remotely:
          * downloads the ISO via the pre-signed URL (Start-BitsTransfer)
          * mounts the ISO
          * runs setup.exe with the ConfigurationFile.ini
          * dismounts the ISO
          * writes a status JSON and transcript to C:\ProgramData\Amazon\HostPrep\

    This script does not apply the post-install SQL baseline. Run
    Apply-SqlBaseline.ps1 separately after this completes.

    Prerequisite: Invoke-HostPrep.ps1 must have run first (drives F: and G: ready).

    The credential must be a local Windows admin on the target EC2 (e.g. .\sqlautomation).
    Do not use AWS IAM credentials here.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TerraformDir = 'terraform/dev',

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'SqlInstall.Config.psd1'),

    [System.Management.Automation.PSCredential]$Credential,

    [string]$UserName = '.\sqlautomation',

    [string[]]$HostName,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-TerraformOutputs {
    param([string]$Directory)

    $resolvedDirectory = (Resolve-Path $Directory).Path
    Write-Host "Reading Terraform outputs from $resolvedDirectory..." -ForegroundColor Cyan

    $json = & terraform -chdir="$resolvedDirectory" output -json
    if (-not $json) {
        throw "Terraform returned no output. Run terraform apply first."
    }

    return $json | ConvertFrom-Json
}

if (-not (Test-Path $ConfigPath)) {
    throw "SQL install config not found: $ConfigPath"
}

$config = Import-PowerShellDataFile -Path $ConfigPath
$terraformOutputs = Get-TerraformOutputs -Directory $TerraformDir

$configuredHosts = @($config.Hosts)
if ($HostName) {
    $configuredHosts = @($configuredHosts | Where-Object { $_.Name -in $HostName })
    if (-not $configuredHosts) {
        throw "No configured hosts matched HostName: $($HostName -join ', ')"
    }
}

if (-not $Credential) {
    $password = Read-Host "Enter password for $UserName" -AsSecureString
    $Credential = New-Object System.Management.Automation.PSCredential($UserName, $password)
}

Write-Host "Using Windows remoting credential: $($Credential.UserName)" -ForegroundColor Cyan

$sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck -OpenTimeout 30000 -OperationTimeout 2700000
$results = New-Object System.Collections.Generic.List[object]

$remoteInstallScript = {
    param(
        [string]$IniContent,
        [string]$PresignedUrl,
        [string]$IsoStagePath,
        [string]$BootstrapRoot,
        [bool]$Force
    )

    $ErrorActionPreference = 'Stop'

    $transcriptPath = Join-Path $BootstrapRoot 'Install-SqlServer.transcript.log'
    $statusPath     = Join-Path $BootstrapRoot 'Install-SqlServer.status.json'

    $sqlService = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
    if ($sqlService -and -not $Force) {
        $status = [pscustomobject]@{
            ComputerName   = $env:COMPUTERNAME
            RanAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
            Success        = $true
            Skipped        = $true
            Reason         = 'MSSQLSERVER service already present. Use -Force to reinstall.'
            TranscriptPath = $null
        }
        $status | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8
        return $status
    }

    Start-Transcript -Path $transcriptPath -Force | Out-Null

    $mountedIso = $null
    try {
        $iniPath = Join-Path $BootstrapRoot 'ConfigurationFile.ini'
        $IniContent | Set-Content -Path $iniPath -Encoding ASCII

        Write-Host "Downloading SQL Server ISO..."
        # WebClient streams directly to disk and works in non-interactive WinRM sessions.
        # Start-BitsTransfer is tied to user session context and fails with 403 over WinRM.
        (New-Object System.Net.WebClient).DownloadFile($PresignedUrl, $IsoStagePath)

        Write-Host "Mounting ISO..."
        $mountedIso = Mount-DiskImage -ImagePath $IsoStagePath -PassThru
        $driveLetter = ($mountedIso | Get-Volume).DriveLetter
        if (-not $driveLetter) {
            throw "Mount-DiskImage did not return a drive letter for $IsoStagePath"
        }

        $setupPath = "${driveLetter}:\setup.exe"

        # SQL Server setup calls ProtectedData.Protect (DPAPI) internally when serialising
        # SqlSecureString to its datastore. DPAPI needs the user key store, which is not
        # accessible in a non-interactive WinRM session. Running setup.exe via a scheduled
        # task as SYSTEM avoids this: SYSTEM has its own DPAPI store that is always present.
        $exitCodePath = Join-Path $BootstrapRoot 'setup-exitcode.txt'
        Remove-Item $exitCodePath -ErrorAction SilentlyContinue

        $launcherPath = Join-Path $BootstrapRoot 'Run-SqlSetup.ps1'
        @"
try {
    `$p = Start-Process -FilePath '$setupPath' ``
        -ArgumentList '/ConfigurationFile=`"$iniPath`"' ``
        -Wait -PassThru -NoNewWindow
    `$p.ExitCode | Set-Content -Path '$exitCodePath' -Encoding UTF8
} catch {
    -1 | Set-Content -Path '$exitCodePath' -Encoding UTF8
    throw
}
"@ | Set-Content -Path $launcherPath -Encoding UTF8

        Unregister-ScheduledTask -TaskName 'SqlServerInstall' -Confirm:$false -ErrorAction SilentlyContinue
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                         -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$launcherPath`""
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 60)
        Register-ScheduledTask -TaskName 'SqlServerInstall' `
            -Action $action -Principal $principal -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName 'SqlServerInstall'

        Write-Host "Running $setupPath via scheduled task (SYSTEM) - this takes 25-30 min..."
        $deadline = (Get-Date).AddMinutes(60)
        do {
            Start-Sleep -Seconds 30
            $taskState = (Get-ScheduledTask -TaskName 'SqlServerInstall').State
            Write-Host "  $([System.DateTime]::UtcNow.ToString('HH:mm:ss')) UTC - task state: $taskState"
        } while ($taskState -eq 'Running' -and (Get-Date) -lt $deadline)

        if ($taskState -ne 'Ready') {
            throw "SQL setup scheduled task did not reach Ready state within 60 min. Final state: $taskState"
        }
        Unregister-ScheduledTask -TaskName 'SqlServerInstall' -Confirm:$false -ErrorAction SilentlyContinue

        if (-not (Test-Path $exitCodePath)) {
            throw "setup.exe exit code file not found at $exitCodePath - launcher script may have failed to start."
        }
        $setupExitCode = [int](Get-Content $exitCodePath -Raw).Trim()

        # 0 = success, 3010 = success with reboot required
        if ($setupExitCode -notin @(0, 3010)) {
            throw "setup.exe exited with code $setupExitCode. Check $transcriptPath and the SQL Server setup log under C:\Program Files\Microsoft SQL Server\<ver>\Setup Bootstrap\Log\"
        }

        $status = [pscustomobject]@{
            ComputerName   = $env:COMPUTERNAME
            RanAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
            Success        = $true
            Skipped        = $false
            ExitCode       = $setupExitCode
            RebootRequired = ($setupExitCode -eq 3010)
            IniPath        = $iniPath
            TranscriptPath = $transcriptPath
        }
        $status | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8

        Write-Host "SQL Server install complete. Exit code: $setupExitCode"
        return $status
    }
    catch {
        $failure = [pscustomobject]@{
            ComputerName   = $env:COMPUTERNAME
            RanAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
            Success        = $false
            Skipped        = $false
            Error          = $_.Exception.Message
            TranscriptPath = $transcriptPath
        }
        $failure | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8
        throw
    }
    finally {
        if ($mountedIso) {
            Dismount-DiskImage -ImagePath $IsoStagePath -ErrorAction SilentlyContinue | Out-Null
        }
        if (Test-Path $IsoStagePath) {
            Remove-Item $IsoStagePath -Force -ErrorAction SilentlyContinue
            Write-Host "ISO removed from $IsoStagePath"
        }
        Stop-Transcript | Out-Null
    }
}

foreach ($targetHost in $configuredHosts) {
    $outputName = [string]$targetHost.TerraformOutputName
    $address    = $terraformOutputs.$outputName.value

    if (-not $address) {
        throw "Missing Terraform output value for $outputName"
    }

    $s3Uri = [string]$targetHost.SqlIsoS3Uri
    if ([string]::IsNullOrWhiteSpace($s3Uri)) {
        throw "SqlIsoS3Uri is not set for $($targetHost.Name) in SqlInstall.Config.psd1"
    }

    $iniFullPath = Join-Path (Get-Location) $targetHost.IniPath
    if (-not (Test-Path $iniFullPath)) {
        throw "INI file not found: $iniFullPath"
    }
    $iniContent = Get-Content -Path $iniFullPath -Raw -Encoding UTF8

    Write-Host "Generating pre-signed S3 URL for $($targetHost.Name)..." -ForegroundColor Cyan
    $presignedUrl = aws s3 presign $s3Uri --expires-in 3600
    if (-not $presignedUrl) {
        throw "aws s3 presign returned no output for $s3Uri. Check your AWS credentials and bucket access."
    }

    Write-Host "Connecting to $($targetHost.Name) at $address..." -ForegroundColor Cyan

    if ($PSCmdlet.ShouldProcess("$($targetHost.Name) ($address)", "Install SQL Server")) {
        try {
            $result = Invoke-Command `
                -ComputerName $address `
                -UseSSL `
                -Port 5986 `
                -Credential $Credential `
                -SessionOption $sessionOption `
                -ScriptBlock $remoteInstallScript `
                -ArgumentList @(
                    $iniContent,
                    $presignedUrl,
                    [string]$config.IsoStagePath,
                    'C:\ProgramData\Amazon\HostPrep',
                    [bool]$Force
                )
        }
        catch {
            throw "SQL install failed for $($targetHost.Name) at $address. Underlying error: $($_.Exception.Message)"
        }

        $results.Add([pscustomobject]@{
            Name    = $targetHost.Name
            Address = $address
            Result  = $result
        })

        if ($result.Skipped) {
            Write-Host "$($targetHost.Name): skipped - $($result.Reason)" -ForegroundColor Yellow
        }
        else {
            Write-Host "$($targetHost.Name): install complete." -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "========== SQL Install Summary ==========" -ForegroundColor Magenta
foreach ($item in $results) {
    $r = $item.Result
    if ($r.Skipped) {
        Write-Host "$($item.Name) -> $($item.Address)  [SKIPPED]" -ForegroundColor Yellow
        Write-Host "  $($r.Reason)"
    }
    elseif ($r.Success) {
        $rebootNote = if ($r.RebootRequired) { '  ** reboot required **' } else { '' }
        Write-Host "$($item.Name) -> $($item.Address)  [OK exit $($r.ExitCode)]$rebootNote" -ForegroundColor Green
        Write-Host "  Transcript: $($r.TranscriptPath)"
    }
    else {
        Write-Host "$($item.Name) -> $($item.Address)  [FAILED]" -ForegroundColor Red
        Write-Host "  $($r.Error)"
        Write-Host "  Transcript: $($r.TranscriptPath)"
    }
}

$rebootHosts = $results | Where-Object { $_.Result.RebootRequired -eq $true }
if ($rebootHosts) {
    Write-Host ""
    Write-Host "The following hosts require a reboot before applying the SQL baseline:" -ForegroundColor Yellow
    foreach ($item in $rebootHosts) {
        Write-Host "  $($item.Name) ($($item.Address))"
    }
    Write-Host ""
    Write-Host "Reboot command (run once per host):" -ForegroundColor Yellow
    foreach ($item in $rebootHosts) {
        Write-Host "  Invoke-Command -ComputerName $($item.Address) -UseSSL -Port 5986 -Credential `$Credential -SessionOption `$sessionOption -ScriptBlock { Restart-Computer -Force }"
    }
    Write-Host ""
    Write-Host "Wait ~2 minutes for WinRM to come back, then run Apply-SqlBaseline.ps1." -ForegroundColor Yellow
}
