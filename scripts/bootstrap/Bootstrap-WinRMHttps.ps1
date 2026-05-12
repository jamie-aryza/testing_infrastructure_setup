<#
.SYNOPSIS
    One-time bootstrap script to enable WinRM over HTTPS for Ansible on a Windows EC2 host.

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

Write-Host "Enabling PowerShell remoting..."
Enable-PSRemoting -Force

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
Set-Item -Path WSMan:\localhost\Service\Auth\Kerberos -Value $true
Set-Item -Path WSMan:\localhost\Service\Auth\Negotiate -Value $true
Set-Item -Path WSMan:\localhost\Service\Auth\Certificate -Value $false

Write-Host "Enabling firewall rule for WinRM HTTPS..."
Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"
New-NetFirewallRule `
    -DisplayName "WinRM HTTPS 5986" `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort 5986 `
    -Profile Any `
    -ErrorAction SilentlyContinue | Out-Null

Write-Host "WinRM HTTPS bootstrap complete."
Write-Host "Thumbprint: $($cert.Thumbprint)"
Write-Host "Remember to trust or pin this certificate from the Ansible control node for safer automation."
