<#
.SYNOPSIS
    Runs pre-SQL Windows host preparation against the dev SQL EC2 instances over WinRM HTTPS.

.DESCRIPTION
    Treats Terraform as the source of truth for the current host addresses, then connects
    to the SQL EC2 instances over WinRM HTTPS and performs the pre-SQL host prep tasks:
      - create the bootstrap working folder
      - set the Windows time zone
      - disable RDP by default
      - initialize, partition, and format the attached SQL data/log disks

    This script is intentionally limited to host preparation only. It does not install
    SQL Server and does not apply any post-install SQL baseline.

    The credential used here must be a Windows account on the target EC2 instances that
    is allowed to remote and perform admin tasks (for example .\Administrator or a
    dedicated local automation admin). Do not use AWS IAM credentials here.
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = 'terraform/dev',

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'HostPrep.Config.psd1'),

    [System.Management.Automation.PSCredential]$Credential,

    [string]$UserName = '.\sqlautomation',

    [string[]]$HostName
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
    throw "Host prep config not found: $ConfigPath"
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

$sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck -OpenTimeout 30000 -OperationTimeout 300000
$results = New-Object System.Collections.Generic.List[object]

$remoteScript = {
    param(
        [string]$TimeZone,
        [bool]$EnableRdp,
        [string]$BootstrapRoot,
        [object[]]$DiskMap,
        [string]$Role,
        [string]$WindowsServerVersion
    )

    $ErrorActionPreference = 'Stop'

    function Resolve-TargetDisk {
        param(
            [object]$DiskConfig
        )

        $systemDriveLetter = $env:SystemDrive.TrimEnd(':')
        $systemPartition = Get-Partition -DriveLetter $systemDriveLetter -ErrorAction Stop
        $systemDiskNumber = $systemPartition.DiskNumber

        $driveLetter = [string]$DiskConfig.DriveLetter
        $expectedSizeGiB = [int]$DiskConfig.ExpectedSizeGiB
        $purpose = [string]$DiskConfig.Purpose

        $existingVolume = try { Get-Volume -DriveLetter $driveLetter -ErrorAction Stop } catch { $null }
        if ($existingVolume) {
            $existingPartition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
            if ($existingPartition.DiskNumber -eq $systemDiskNumber) {
                throw "Configured drive letter $driveLetter is on the system disk. Refusing to continue."
            }

            return Get-Disk -Number $existingPartition.DiskNumber -ErrorAction Stop
        }

        $candidateDisks = Get-Disk | Where-Object {
            $_.Number -ne $systemDiskNumber -and
            [math]::Abs(($_.Size / 1GB) - $expectedSizeGiB) -lt 1
        }

        if (-not $candidateDisks) {
            throw "Could not find a non-system disk for $purpose with expected size ${expectedSizeGiB}GiB."
        }

        if (@($candidateDisks).Count -gt 1) {
            $diskNumbers = ($candidateDisks | Select-Object -ExpandProperty Number) -join ', '
            throw "Multiple non-system disks matched $purpose (${expectedSizeGiB}GiB): $diskNumbers. Refusing to guess."
        }

        return $candidateDisks | Select-Object -First 1
    }

    $summary = [ordered]@{
        ComputerName         = $env:COMPUTERNAME
        Role                 = $Role
        WindowsServerVersion = $WindowsServerVersion
        TimeZone             = $TimeZone
        BootstrapRoot        = $BootstrapRoot
        RdpEnabled           = $EnableRdp
        PreparedDrives       = @()
    }

    if (-not (Test-Path -LiteralPath $BootstrapRoot)) {
        New-Item -ItemType Directory -Path $BootstrapRoot -Force | Out-Null
    }

    Set-TimeZone -Id $TimeZone

    $rdpValue = if ($EnableRdp) { 0 } else { 1 }
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value $rdpValue

    foreach ($disk in $DiskMap) {
        $targetDisk = Resolve-TargetDisk -DiskConfig $disk
        $diskNumber = [int]$targetDisk.Number
        $driveLetter = [string]$disk.DriveLetter
        $label = [string]$disk.Label
        $purpose = [string]$disk.Purpose

        if ($targetDisk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $diskNumber -PartitionStyle GPT -ErrorAction Stop | Out-Null
            $targetDisk = Get-Disk -Number $diskNumber -ErrorAction Stop
        }

        if ($targetDisk.IsOffline) {
            Set-Disk -Number $diskNumber -IsOffline $false -ErrorAction Stop
        }

        if ($targetDisk.IsReadOnly) {
            Set-Disk -Number $diskNumber -IsReadOnly $false -ErrorAction Stop
        }

        $partition = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $driveLetter } | Select-Object -First 1
        if (-not $partition) {
            # Exclude Reserved (MSR) partitions — GPT disks always have one and it is not usable as a data partition.
            $partition = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Where-Object { $_.Type -notin @('Reserved', 'Unknown') } | Select-Object -First 1
        }

        if (-not $partition) {
            $partition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -DriveLetter $driveLetter -ErrorAction Stop
        }
        elseif ($partition.DriveLetter -ne $driveLetter) {
            $partition | Set-Partition -NewDriveLetter $driveLetter -ErrorAction Stop
            $partition = Get-Partition -DiskNumber $diskNumber -ErrorAction Stop | Where-Object { $_.DriveLetter -eq $driveLetter } | Select-Object -First 1
        }

        $volume = try { Get-Volume -DriveLetter $driveLetter -ErrorAction Stop } catch { $null }
        if (-not $volume -or $volume.FileSystem -ne 'NTFS') {
            # Format-Volume via CIM cannot create a new volume on a raw partition in a remoting
            # session. diskpart bypasses this reliably. Drive letter assignment is also done here
            # because New-Partition -DriveLetter does not reliably persist the letter over WinRM.
            "select disk $diskNumber`nselect partition $($partition.PartitionNumber)`nformat fs=ntfs label=$label unit=64k quick`nassign letter=$driveLetter" |
                diskpart | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "diskpart format failed for $purpose (disk $diskNumber, partition $($partition.PartitionNumber))" }
        }
        else {
            Set-Volume -DriveLetter $driveLetter -NewFileSystemLabel $label -ErrorAction Stop
        }

        $summary.PreparedDrives += "$driveLetter ($label, disk $diskNumber, $purpose)"
    }

    [pscustomobject]$summary
}

foreach ($targetHost in $configuredHosts) {
    $outputName = [string]$targetHost.TerraformOutputName
    $address = $terraformOutputs.$outputName.value

    if (-not $address) {
        throw "Missing Terraform output value for $outputName"
    }

    Write-Host "Connecting to $($targetHost.Name) at $address..." -ForegroundColor Cyan

    try {
        $result = Invoke-Command `
            -ComputerName $address `
            -UseSSL `
            -Port 5986 `
            -Credential $Credential `
            -SessionOption $sessionOption `
            -ScriptBlock $remoteScript `
            -ArgumentList @(
                [string]$config.TimeZone,
                [bool]$config.EnableRdp,
                [string]$config.BootstrapRoot,
                [object[]]$config.DiskMap,
                [string]$targetHost.Role,
                [string]$targetHost.WindowsServerVersion
            )
    }
    catch {
        throw "Host prep failed for $($targetHost.Name) at $address using Windows credential '$($Credential.UserName)'. Confirm you are using a local Windows admin credential on the EC2 host (for example .\Administrator), not AWS IAM credentials. Underlying error: $($_.Exception.Message)"
    }

    $results.Add([pscustomobject]@{
        Name                 = $targetHost.Name
        Address              = $address
        Role                 = $targetHost.Role
        WindowsServerVersion = $targetHost.WindowsServerVersion
        Result               = $result
    })

    Write-Host "Host prep completed for $($targetHost.Name)." -ForegroundColor Green
}

Write-Host ""
Write-Host "========== Host Prep Summary ==========" -ForegroundColor Magenta
foreach ($item in $results) {
    Write-Host "$($item.Name) [$($item.Role) / Windows $($item.WindowsServerVersion)] -> $($item.Address)" -ForegroundColor Green
    Write-Host "  Bootstrap root:  $($item.Result.BootstrapRoot)"
    Write-Host "  Time zone:       $($item.Result.TimeZone)"
    Write-Host "  RDP enabled:     $($item.Result.RdpEnabled)"
    Write-Host "  Prepared drives: $($item.Result.PreparedDrives -join ', ')"
}
