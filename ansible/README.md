# Ansible Host Prep

This folder is no longer the primary automation path for the PoC. The repo is pivoting toward `Terraform + WinRM + PowerShell` because that is a lower-friction fit for a Windows-heavy DBA workflow and matches the existing SQL Server/dbatools scripts better.

This folder owns pre-SQL Windows host preparation for the AWS SQL Server EC2 instances.

Current scope:
- Bootstrap WinRM over HTTPS on the Windows host
- Run first-boot host prep tasks
- Prepare extra disks for future SQL data/log usage

Out of scope for now:
- SQL Server installation
- Post-install SQL baseline application
- Test/prod environment orchestration

## Layout

- `ansible.cfg` - local Ansible defaults for this repo
- `inventories/dev/hosts.yml.example` - example dev inventory
- `group_vars/windows_sql_hosts.yml` - shared host-prep defaults
- `playbooks/windows-host-prep.yml` - pre-SQL host prep playbook
- `roles/windows_host_prep/` - reusable Windows host prep role

## Intended flow

1. Create a repo-local Python virtual environment and install the Ansible Python dependencies:

If you are on a Windows admin machine, install WSL first from an elevated PowerShell window:

```powershell
wsl --install
```

Then open WSL and run the commands below from there rather than from native Windows Python.

On a Windows machine, do this from WSL rather than native Windows Python. Ansible is the control-node tool here, and WSL avoids the Windows runtime issues that show up with `ansible` and `ansible-galaxy`.

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r ansible/requirements.yml
```

   Keep Terraform and AWS CLI installed normally on the machine. The repo-local `.venv` is for Ansible and Python-side WinRM dependencies only.
2. Bootstrap WinRM HTTPS on the EC2 via `user_data` or one-time console access.
3. Generate the real inventory from Terraform after `terraform apply`:

```powershell
.\scripts\ansible\Generate-AnsibleInventory.ps1
```

   This keeps Terraform as the source of truth for the current public IPs.
   The example inventory remains as a reference for the expected shape.
4. Run the host-prep playbook:

```bash
ansible-playbook -i inventories/dev/hosts.yml playbooks/windows-host-prep.yml
```

## Notes

- Treat this Ansible scaffolding as experimental/reference material unless you explicitly choose to keep using it.
- The PoC access model is public IP + admin CIDR allowlist + WinRM HTTPS on port `5986`.
- RDP is optional break-glass access only if you decide to retain it.
- For this PoC, `dev-live` is expected to run Windows Server 2022 and `dev-test` Windows Server 2016.
- Treat those as inventory data, not permanent code assumptions, so the mapping can change later without rewriting the role.
- Long term, these hosts should move to private subnets and be reached through a bastion or VPN.
