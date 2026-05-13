# DevOps Learning Project

A phased DevOps learning project building a full CI/CD pipeline across Dev, Test, and Prod environments using AWS, Terraform, GitHub Actions, SQL Server, and a .NET microservice.

For the current Windows-heavy SQL Server PoC, the preferred automation path is `Terraform + WinRM + PowerShell`. Ansible was explored for Windows host prep, but has been dropped from the active path because PowerShell is a lower-friction fit on a Windows admin machine and lines up better with the repo's existing SQL Server and `dbatools` scripts.

This is a PoC convenience choice, not the long-term target design. WinRM over HTTPS is being used now because it is the most straightforward native PowerShell remoting path from a Windows admin machine while the SQL install and post-install workflow is still PowerShell-first. Once the PoC is proven, the long-term options are to move the SQL hosts into a private subnet and manage them either over WinRM HTTPS through a bastion/VPN or via AWS Systems Manager (SSM) if that proves to be the better operational fit.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design rationale, phase status, and PoC-to-production roadmap.

## Project Structure

```
terraform/
  dev/              # Dev environment (providers.tf, variables.tf, main.tf)
  test/             # Test environment (same structure as dev)
  modules/
    vpc/            # VPC, subnets, IGW, route tables
    sql-server/     # EC2 SQL Server module (AMI, EBS, security group)
scripts/
  bootstrap/        # PowerShell bootstrap and pre-SQL host prep scripts
  inventory/        # PowerShell + dbatools scripts to capture/apply SQL config as JSON
  sql-install/      # SQL Server install configuration files and wrappers
infrastructure-baseline/
  <server-name>/    # JSON snapshot of prod (sp_configure, trace flags, etc.)
app/
  .github/
    workflows/      # GitHub Actions CI/CD pipelines
```

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| AWS CLI v2 | Authenticate to AWS from the terminal | [aws.amazon.com/cli](https://aws.amazon.com/cli) |
| Terraform | Provision AWS infrastructure as code | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) |
| Git | Version control | [git-scm.com](https://git-scm.com) |

## AWS CLI Setup

The AWS CLI is how Terraform authenticates to your AWS account. You only need to do this once per machine.

**1. Create an IAM user** in the AWS Console (IAM → Users → Create user). Attach the `AdministratorAccess` policy for learning purposes. Generate an Access Key (CLI type) and copy the Access Key ID and Secret Access Key.

**2. Configure the CLI:**

```bash
aws configure
```

You'll be prompted for:
- AWS Access Key ID
- AWS Secret Access Key
- Default region name → `eu-west-2` (London)
- Default output format → `json`

This writes credentials to `~/.aws/credentials` and config to `~/.aws/config`. Terraform's AWS provider reads from these automatically.

**3. Verify it works:**

```bash
aws sts get-caller-identity
```

Should print your account ID and IAM user ARN. If it errors, your credentials are wrong or expired.

## Terraform Workflow

Terraform commands always run from inside an environment folder (e.g. [terraform/dev/](terraform/dev/)). Each environment has its own state file, so dev and test cannot interfere with each other.

```bash
cd terraform/dev
```

### First-time setup: `terraform.tfvars`

Each environment requires a local `terraform.tfvars` (gitignored) for values that shouldn't go in source control. For dev, set `admin_cidr` there, and provide the local Windows automation admin password through an environment variable so it does not sit in a file.

Copy the example and fill in your public IP:

```bash
cp terraform.tfvars.example terraform.tfvars
# then edit terraform.tfvars and replace the placeholder with your IP
```

Set the local Windows automation admin password before `terraform apply`:

```powershell
$env:TF_VAR_automation_admin_password = "replace-with-a-strong-password"
```

You can optionally change `automation_admin_username` in `terraform.tfvars`. The default is `sqlautomation`.

Get your current public IP:

```bash
curl https://checkip.amazonaws.com
```

Use it as a `/32` CIDR (single host), e.g. `203.0.113.42/32`. If your home IP changes, update `terraform.tfvars` and re-run `terraform apply` — the security group rule will be replaced.

### `terraform init`

Run this **once per environment folder**, and again any time you add a new module or provider.

```bash
terraform init
```

What it does:
- Downloads the AWS provider plugin from the HashiCorp registry
- Initialises the modules referenced in `main.tf` (e.g. `../modules/vpc`)
- Sets up the local `.terraform/` directory and `.terraform.lock.hcl` lock file

### `terraform plan`

Previews what Terraform *would* do, without making any changes. Always run this before `apply`.

```bash
terraform plan
```

The output shows resources to be added (`+`), changed (`~`), or destroyed (`-`). Read it carefully — especially the destroy lines.

### `terraform apply`

Actually creates, updates, or destroys AWS resources to match your `.tf` files.

```bash
terraform apply
```

Terraform shows the same plan as `plan`, then asks `Enter a value:` — type `yes` to proceed. To skip the prompt (e.g. in CI):

```bash
terraform apply -auto-approve
```

### `terraform destroy`

Tears down everything Terraform manages in this environment. Useful for cleaning up between learning sessions to avoid AWS charges.

```bash
terraform destroy
```

### `terraform fmt` and `terraform validate`

Quick health checks:

```bash
terraform fmt -recursive    # auto-format .tf files
terraform validate          # syntax + reference check (no AWS calls)
```

## PowerShell Host Prep

After `terraform apply`, run the pre-SQL Windows host prep from your admin machine:

```powershell
.\scripts\bootstrap\Invoke-HostPrep.ps1
```

By default, the script prompts in the terminal for the password of the local Windows automation account `.\sqlautomation`, so you do not need to use the Windows credential popup.

If you changed the automation username, pass it explicitly:

```powershell
.\scripts\bootstrap\Invoke-HostPrep.ps1 -UserName ".\yourusername"
```

This uses Terraform outputs as the source of truth for the current host IPs and performs only the pre-SQL Windows tasks:
- create the bootstrap working folder
- set the Windows time zone
- disable RDP by default
- initialize, partition, and format the attached SQL data/log disks

For the current PoC, this remoting step uses WinRM over HTTPS from a fixed admin CIDR because it keeps the PowerShell workflow simple on a Windows machine. Long term, the preferred hardening move is private-subnet SQL hosts with either bastion/VPN-backed WinRM or SSM-based management so public management exposure can be removed.

Important: the password prompt here is for a Windows account on the EC2 instance that is allowed to remote and perform admin tasks. It is not asking for AWS IAM credentials.

## SQL Server Install

Run this after `Invoke-HostPrep.ps1` has completed (F: and G: disks must be formatted first).

**One-time admin setup (do this before the first install):**

1. **Get the SQL Server Developer ISO.** Download SQL Server 2019 Developer (free) from [microsoft.com/en-us/sql-server/sql-server-downloads](https://www.microsoft.com/en-us/sql-server/sql-server-downloads) → Developer edition → ISO download option.

2. **Create an S3 bucket** to store the ISO. The bucket name must be globally unique across all AWS accounts:
   ```powershell
   aws s3 mb s3://aryza-sql-server-install --region eu-west-2
   ```

3. **Upload the ISO:**
   ```powershell
   aws s3 cp "SQLServer2019-x64-ENU-Dev.iso" s3://aryza-sql-server-install/sql2019-developer-x64.iso
   ```
   This is a ~1.5 GB upload — takes a few minutes on a typical home connection. The ISO is gitignored and lives in S3 only.

4. **Update `SqlIsoS3Uri`** for both hosts in [scripts/sql-install/SqlInstall.Config.psd1](scripts/sql-install/SqlInstall.Config.psd1) to match the bucket name used above (e.g. `s3://aryza-sql-server-install/sql2019-developer-x64.iso`). Both entries use the same ISO. If you ever rename the bucket, this config file is the only place to update.

**Run the install:**

```powershell
.\scripts\sql-install\Invoke-SqlInstall.ps1
```

To target a single host:

```powershell
.\scripts\sql-install\Invoke-SqlInstall.ps1 -HostName dev-live
```

As with host prep, the script prompts for the `.\sqlautomation` password. Pass `-UserName` if you changed it.

The install takes roughly 25–30 minutes per host. The script writes a transcript and status JSON to `C:\ProgramData\Amazon\HostPrep\` on the EC2 — check `Install-SqlServer.status.json` there if something goes wrong.

Re-running without `-Force` detects the existing `MSSQLSERVER` service and skips safely. To reinstall:

```powershell
.\scripts\sql-install\Invoke-SqlInstall.ps1 -Force
```

**S3 bucket cleanup:**

The ISO bucket is not managed by Terraform — clean it up manually when no longer needed.

Empty the bucket (keep the name reserved):
```powershell
aws s3 rm s3://aryza-sql-server-install --recursive
```

Delete the bucket entirely (frees the name):
```powershell
aws s3 rb s3://aryza-sql-server-install --force
```

If you plan to reinstall later, keeping the empty bucket avoids having to re-upload the ISO. If you delete the bucket, re-run the one-time setup steps above before the next install.

**After install**, run post-install configuration. This applies the prod baseline (sp_configure, trace flags, DBMail) and host-specific tuning (memory, MAXDOP, tempdb, pipeline login) in a single script:

```powershell
# Full apply for dev - reads PostInstall.Dev.Config.psd1 automatically
.\scripts\sql-install\Invoke-PostInstall.ps1

# Dry run - shows what would change, makes nothing
.\scripts\sql-install\Invoke-PostInstall.ps1 -WhatIf

# Re-sync prod config only (no sizing or login changes)
.\scripts\sql-install\Invoke-PostInstall.ps1 -Mode ProdSync

# Host-specific tuning only (no sp_configure/trace/mail changes)
.\scripts\sql-install\Invoke-PostInstall.ps1 -Mode HostSpecific

# Test environment, single host
.\scripts\sql-install\Invoke-PostInstall.ps1 -TerraformDir terraform/test -HostName test-sql-live
```

The script reads `scripts/sql-install/PostInstall.Dev.Config.psd1` (or `PostInstall.Test.Config.psd1` for test) for the baseline path, DBMail mode, and login settings. This file is updated automatically when you run `Inventory-SqlServer.ps1 -Environment Dev`. Review `TargetDatabase` in the config before running if you want the pipeline login granted db_owner on a specific database.

The script prompts for two passwords: the `.\sqlautomation` WinRM credential and the `gha_deploy` SQL login password (skipped for `-Mode ProdSync`). Store the `gha_deploy` password as a GitHub Actions secret.

**What is `gha_deploy`?** It is the SQL Server login that GitHub Actions uses to connect to the target database and deploy objects (tables, stored procedures, views, etc.). It is created as a SQL auth login (username + password, no Windows/domain dependency) with `db_owner` on the target database. The password is set once during post-install and stored as a GHA secret, then referenced in the deployment workflow: `${{ secrets.GHA_DEPLOY_PASSWORD }}`.

## Typical Day-to-Day Flow

```bash
cd terraform/dev
# edit main.tf or a module...
terraform fmt
terraform plan              # review the diff
terraform apply             # deploy
# ...later, when done for the day:
terraform destroy           # tear down to save money
```

## Notes

- **SQL Server Browser must be enabled** to run `Inventory-SqlServer.ps1` against a local named instance (e.g. `.\LIVE`). Browser is disabled by default on many installs. Enable it in an elevated PowerShell session: `Set-Service SQLBrowser -StartupType Automatic; Start-Service SQLBrowser`. Not needed for default instances or when connecting by port number directly.
- The AWS provider is configured for `eu-west-2` (London).
- Free tier covers t2/t3.micro EC2, 30GB EBS, and 750 hours/month of compute. NAT gateways and Elastic IPs (when unattached) are *not* free — this project deliberately avoids them.
- Never commit `.terraform/`, `*.tfstate`, or `*.tfvars` files containing secrets. The `.gitignore` should already exclude these.
- **Prefer Windows Server Core AMIs** for SQL Server hosts that do not need a UI. Core has a smaller attack surface, lower memory footprint, and faster patch cycles. The bootstrap and SQL install scripts are UI-agnostic and work on Core. Use Desktop Experience only if you need GUI tools on the host itself (e.g. SSMS installed locally), which is not the target pattern for this pipeline.
