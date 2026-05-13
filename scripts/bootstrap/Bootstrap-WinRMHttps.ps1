<#
.SYNOPSIS
    One-time bootstrap script to enable WinRM over HTTPS for PowerShell remoting on a Windows EC2 host.

.DESCRIPTION
    Intended for the PoC access model:
      - public IP on the EC2
      - inbound 5986 restricted to a fixed admin CIDR
      - WinRM over HTTPS as the standard admin/automation path

    This script:
      - enables PS remoting
      - creates a self-signed certificate for the host
      - binds a WinRM HTTPS listener on 5986
      - enables the Windows firewall rule for WinRM HTTPS

    Long term, move these hosts to a private subnet and reach them through a bastion or VPN.
#>
[CmdletBinding()]
param(
    [string]$DnsName = $env:COMPUTERNAME
)

$ErrorActionPreference = "Stop"

function ConvertFrom-TemplateBase64 {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}

$bootstrapLogRoot = 'C:\ProgramData\Amazon\WinRMBootstrap'
$null = New-Item -ItemType Directory -Path $bootstrapLogRoot -Force

$transcriptPath = Join-Path $bootstrapLogRoot 'Bootstrap-WinRMHttps.transcript.log'
$statusPath = Join-Path $bootstrapLogRoot 'Bootstrap-WinRMHttps.status.json'

$automationAdminUsername = ConvertFrom-TemplateBase64 '${automation_admin_username_b64}'
$automationAdminPassword = ConvertFrom-TemplateBase64 '${automation_admin_password_b64}'

# Windows rejects passwords that share any 3+ character substring with the account name (case-insensitive),
# even if they pass the length and complexity checks. Validate both in terraform.tfvars before deploying.
if ([string]::IsNullOrWhiteSpace($automationAdminUsername) -or [string]::IsNullOrWhiteSpace($automationAdminPassword)) {
    throw "Automation admin bootstrap values were not provided. Set automation_admin_username and automation_admin_password in terraform.tfvars."
}

Start-Transcript -Path $transcriptPath -Force | Out-Null

try {
    Write-Host "Enabling PowerShell remoting..."
    Enable-PSRemoting -Force -SkipNetworkProfileCheck

    Write-Host "Creating or updating local automation admin..."
    # New-LocalUser/Set-LocalUser fail with passwords containing @ via SecureString on this AMI.
    # net user handles it reliably.
    $existingAutomationAdmin = Get-LocalUser -Name $automationAdminUsername -ErrorAction SilentlyContinue
    if (-not $existingAutomationAdmin) {
        net user $automationAdminUsername $automationAdminPassword /add /passwordchg:no /expires:never | Out-Null
    }
    else {
        net user $automationAdminUsername $automationAdminPassword | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "net user failed with exit code $LASTEXITCODE" }

    $isAdministrator = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | Where-Object {
        $_.Name -eq "$env:COMPUTERNAME\$automationAdminUsername"
    }
    if (-not $isAdministrator) {
        net localgroup Administrators $automationAdminUsername /add | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "net localgroup failed with exit code $LASTEXITCODE" }
    }

    Write-Host "Relaxing local-account UAC filtering for remote admin tasks (PoC only)..."
    New-ItemProperty `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name 'LocalAccountTokenFilterPolicy' `
        -PropertyType DWord `
        -Value 1 `
        -Force | Out-Null

    Write-Host "Creating self-signed certificate for WinRM HTTPS..."
    $cert = New-SelfSignedCertificate `
        -DnsName $DnsName `
        -CertStoreLocation Cert:\LocalMachine\My `
        -FriendlyName "WinRM HTTPS Bootstrap"

    Write-Host "Removing existing WinRM HTTPS listener if present..."
    $httpsListener = Get-ChildItem WSMan:\Localhost\Listener | Where-Object {
        $_.Keys -match "Transport=HTTPS"
    }

    foreach ($listener in $httpsListener) {
        Remove-Item -Path $listener.PSPath -Recurse -Force
    }

    Write-Host "Creating WinRM HTTPS listener on 5986..."
    New-Item `
        -Path WSMan:\LocalHost\Listener `
        -Transport HTTPS `
        -Address * `
        -CertificateThumbPrint $cert.Thumbprint `
        -Force | Out-Null

    Write-Host "Configuring WinRM service..."
    Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false
    Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $false
    Set-Item -Path WSMan:\localhost\Service\Auth\CredSSP -Value $false
    Set-Item -Path WSMan:\localhost\Service\Auth\Negotiate -Value $true
    Set-Item -Path WSMan:\localhost\Service\Auth\Certificate -Value $false

    Write-Host "Removing HTTP listener (5985) left by Enable-PSRemoting..."
    $httpListeners = Get-ChildItem WSMan:\Localhost\Listener | Where-Object {
        $_.Keys -match "Transport=HTTP"
    }
    foreach ($listener in $httpListeners) {
        Remove-Item -Path $listener.PSPath -Recurse -Force
    }

    Write-Host "Enabling firewall rule for WinRM HTTPS..."
    Enable-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName "WinRM HTTPS 5986" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 5986 `
        -Profile Any `
        -ErrorAction SilentlyContinue | Out-Null

    $httpsListeners = @(Get-ChildItem WSMan:\Localhost\Listener | Where-Object { $_.Keys -match 'Transport=HTTPS' })
    if (-not $httpsListeners) {
        throw "WinRM HTTPS listener was not present after bootstrap."
    }

    $status = [pscustomobject]@{
        ComputerName      = $env:COMPUTERNAME
        RanAtUtc          = (Get-Date).ToUniversalTime().ToString('o')
        Success           = $true
        AutomationUser    = $automationAdminUsername
        WinRMHttpsPort    = 5986
        ListenerCount     = $httpsListeners.Count
        CertificateThumb  = $cert.Thumbprint
        TranscriptPath    = $transcriptPath
    }
    $status | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8

    Write-Host "WinRM HTTPS bootstrap complete."
    Write-Host "Thumbprint: $($cert.Thumbprint)"
    Write-Host "Bootstrap status written to $statusPath"
    Write-Host "Remember to trust or pin this certificate from the admin machine for safer automation."
}
catch {
    $failure = [pscustomobject]@{
        ComputerName   = $env:COMPUTERNAME
        RanAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
        Success        = $false
        Error          = $_.Exception.Message
        TranscriptPath = $transcriptPath
    }
    $failure | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8
    Write-Error "Bootstrap-WinRMHttps.ps1 failed: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
