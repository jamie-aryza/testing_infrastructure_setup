<#
.SYNOPSIS
    Generates the dev Ansible inventory from Terraform outputs.

.DESCRIPTION
    Treats Terraform as the source of truth for dev host addressing and writes
    an Ansible inventory file for the Windows SQL hosts. The generated file
    contains the current public IPs plus the fixed PoC host metadata.

    Run this after `terraform apply` in `terraform/dev`.
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = "terraform/dev",
    [string]$OutputPath = "ansible/inventories/dev/hosts.yml"
)

$ErrorActionPreference = "Stop"

$resolvedTerraformDir = Resolve-Path $TerraformDir
$resolvedOutputPath = Join-Path (Get-Location) $OutputPath
$outputDir = Split-Path -Parent $resolvedOutputPath

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

Write-Host "Reading Terraform outputs from $resolvedTerraformDir..."
$tfJson = & terraform -chdir="$resolvedTerraformDir" output -json
if (-not $tfJson) {
    throw "Terraform returned no output. Run terraform apply first."
}

$tf = $tfJson | ConvertFrom-Json

$liveIp = $tf.sql_live_public_ip.value
$testIp = $tf.sql_test_public_ip.value

if (-not $liveIp -or -not $testIp) {
    throw "Missing required Terraform outputs for sql_live_public_ip or sql_test_public_ip."
}

$inventory = @"
all:
  children:
    windows_sql_hosts:
      hosts:
        dev-live:
          ansible_host: $liveIp
          sql_host_role: live
          windows_server_version: "2022"
        dev-test:
          ansible_host: $testIp
          sql_host_role: test
          windows_server_version: "2016"
      vars:
        ansible_connection: winrm
        ansible_port: 5986
        ansible_winrm_transport: ntlm
        ansible_winrm_scheme: https
        ansible_winrm_server_cert_validation: ignore
        ansible_user: Administrator
        ansible_password: CHANGE_ME
"@

Set-Content -Path $resolvedOutputPath -Value $inventory -Encoding utf8

Write-Host "Wrote Ansible inventory to $resolvedOutputPath" -ForegroundColor Green
Write-Host "dev-live  -> $liveIp"
Write-Host "dev-test  -> $testIp"
