# Temporary Pivot Notes

Working decision for the current PoC:
- Keep Terraform for infrastructure provisioning
- Keep WinRM over HTTPS as the Windows management path
- Pivot from Ansible-first orchestration to PowerShell-first orchestration

Why:
- Lower friction on a Windows admin machine
- Better fit for a Windows-heavy DBA workflow
- Reuses existing PowerShell and dbatools scripts already in the repo
- Avoids making WSL/Ansible collections a required day-to-day dependency
- Keeps the current PoC simple while leaving room to move to bastion/VPN-backed WinRM or SSM later

Execution split we are moving toward:
- Pre-SQL host prep: PowerShell remoting over WinRM
- SQL install orchestration: PowerShell wrapper around `setup.exe` and `.ini` files
- Post-install SQL config: existing PowerShell/dbatools baseline scripts

Temporary file for working context. Safe to delete once the pivot is fully implemented and documented elsewhere.
