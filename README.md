# DevOps Learning Project

A phased DevOps learning project building a full CI/CD pipeline across Dev, Test, and Prod environments using AWS, Terraform, GitHub Actions, SQL Server, and a .NET microservice.

For the current Windows-heavy SQL Server PoC, the preferred automation path is `Terraform + WinRM + PowerShell`. Ansible was explored for Windows host prep, but has been de-prioritized because PowerShell is a lower-friction fit on a Windows admin machine and lines up better with the repo's existing SQL Server and `dbatools` scripts.

See [DevOps_Learning_Roadmap.md](DevOps_Learning_Roadmap.md) for the full learning plan.

## Project Structure

```
terraform/
  dev/              # Dev environment (providers.tf, variables.tf, main.tf)
  test/             # Test environment (same structure as dev)
  modules/
    vpc/            # VPC, subnets, IGW, route tables
    sql-server/     # EC2 SQL Server module (AMI, EBS, security group)
scripts/
  inventory/        # PowerShell + dbatools scripts to capture prod SQL config as JSON
  sql-install/      # ConfigurationFile.ini (live/test) + Install-SqlServer.ps1
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

Each environment requires a local `terraform.tfvars` (gitignored) for values that shouldn't go in source control. For dev, the only required variable is `admin_cidr` — the IP allowed WinRM HTTPS (5986) access to the SQL Server EC2s.

Copy the example and fill in your public IP:

```bash
cp terraform.tfvars.example terraform.tfvars
# then edit terraform.tfvars and replace the placeholder with your IP
```

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

- The AWS provider is configured for `eu-west-2` (London).
- Free tier covers t2/t3.micro EC2, 30GB EBS, and 750 hours/month of compute. NAT gateways and Elastic IPs (when unattached) are *not* free — this project deliberately avoids them.
- Never commit `.terraform/`, `*.tfstate`, or `*.tfvars` files containing secrets. The `.gitignore` should already exclude these.
