# DevOps Learning Roadmap

Cloud Dev & Test | On-Prem Production | GitHub Actions CI/CD

**Stack:** AWS | SQL Server x2 | .NET Microservice | GitHub Actions

## 1. The Big Picture

Before touching a single command, it helps to understand the full landscape you are building. Your eventual setup will look like this:

| Environment | Where | SQL Server | App / Service |
|---|---|---|---|
| Dev | AWS (cloud) | 2x EC2 SQL Server | EC2 instance |
| Test | AWS (cloud) | 2x EC2 SQL Server | EC2 instance |
| Production | On-premises | 2x SQL Server on Windows Server | App server on-prem |

CI/CD (Continuous Integration / Continuous Deployment) sits above all three environments. A single push to GitHub triggers automated build, test, and deploy steps that move your code from Dev → Test → Prod with appropriate checks and approvals at each gate.

### Why this setup mirrors real enterprise work

- Dev is disposable — spin it up cheaply in the cloud, break things freely.
- Test mirrors production data shapes so bugs surface before they go live.
- Prod on-prem is common in regulated industries (finance, healthcare, public sector).
- GitHub Actions is the most widely adopted CI/CD tool in the industry right now.
- SQL Server x2 teaches you primary/secondary patterns (e.g. OLTP + reporting).

### Your Learning Path at a Glance

| Phase | What you will build / learn |
|---|---|
| 0 - Foundations | AWS account, IAM, CLI, GitHub repo, Terraform basics, key terms |
| 1 - Dev on AWS | VPC, 2x EC2 SQL Server, EC2 + dummy microservice, secrets |
| 2 - Test on AWS | Identical isolated environment, environment promotion strategy |
| 3 - Prod on-prem | Windows Server, SQL Server, VPN tunnel to AWS, firewall rules |
| 4 - GitHub Actions | Pipelines, build → test → deploy, approval gates, secrets |
| 5 - End-to-end | Full push-to-deploy flow across all three environments |

---

## Phase 0 — Foundations: Tools, Accounts & Key Concepts

*Week 1*

Get your toolbelt in order before writing any infrastructure code. None of these take long, but skipping them causes pain later.

### 2.1 Accounts & Access

You will need:

- **An AWS account** — the free tier covers everything in Phase 1 & 2. Sign up at aws.amazon.com.
- **A GitHub account** — this is where your code and pipelines live.
- **An IAM user (not root!)** — once logged in to AWS, go to IAM → Users → Create user. Attach the `AdministratorAccess` policy for learning purposes (you can tighten this later). Generate an Access Key — you will need it for the CLI.

### 2.2 Tools to Install on Your Machine

| Tool | What it does & where to get it |
|---|---|
| AWS CLI v2 | Control AWS from the terminal. docs.aws.amazon.com/cli → install, then run: `aws configure` |
| Terraform | Writes your cloud infrastructure as code. developer.hashicorp.com/terraform/install |
| Git | Version control. git-scm.com (already installed on most machines) |
| VS Code | The recommended editor. Install the Terraform and YAML extensions. |
| SQL Server Management Studio (SSMS) | Connect to your SQL Server instances. aka.ms/ssms |
| Docker Desktop (optional) | Run your microservice locally before deploying. docker.com |

### 2.3 Key Terms Glossary

| Term | Plain-English meaning |
|---|---|
| VPC | Virtual Private Cloud — your private network inside AWS. Think of it as your own walled-off section of AWS. |
| Subnet | A subdivision of a VPC. Public subnets can reach the internet; private subnets cannot (where your SQL Server should live). |
| Security Group | A virtual firewall attached to an AWS resource. Controls which ports and IP addresses can talk to it. |
| EC2 | Elastic Compute Cloud — a virtual machine in the cloud. Your microservice and SQL Server instances will run here. |
| IAM | Identity and Access Management — controls who (users, services, pipelines) can do what in AWS. |
| Terraform | A tool that lets you describe infrastructure in code files (.tf). Run `terraform apply` and it creates the resources for you. |
| GitHub Actions | A CI/CD engine built into GitHub. You write workflow files in YAML; GitHub runs them automatically on events like a code push. |
| CI/CD | Continuous Integration / Continuous Deployment. CI = automated build + test on every commit. CD = automated deployment to an environment. |
| Pipeline | The sequence of steps (build → test → deploy) that run automatically when you push code. |
| Secret | A sensitive value (password, API key) stored securely and injected into a pipeline or app at runtime — never hard-coded. |
| VPN Gateway | An encrypted tunnel connecting your AWS VPC to your on-prem network, so they can talk to each other privately. |
| IaC | Infrastructure as Code — defining your servers, databases, and networks in text files rather than clicking in a console. |

### 2.4 Set Up Your GitHub Repository

Create a repository called `devops-learning` (or similar) with this folder structure:

```
devops-learning/
├── terraform/
│   ├── dev/              # Dev environment (providers.tf, variables.tf, main.tf)
│   ├── test/             # Test environment (same structure as dev)
│   └── modules/
│       ├── vpc/          # VPC, subnets, IGW, route tables
│       └── sql-server/   # EC2 SQL Server module (AMI, EBS, security group)
├── app/                  # Your dummy microservice source code
└── .github/
    └── workflows/        # GitHub Actions pipeline files (.yml)
```

**Tip:** keeping dev and test as separate Terraform folders means you can apply them independently and they have no shared state.

---

## Phase 1 — Dev Environment on AWS

*Weeks 2–3*

This is the environment you will break and rebuild freely. Everything here is defined in Terraform so you can tear it down and recreate it in minutes.

### 3.1 Networking — VPC & Subnets

Every AWS resource lives inside a VPC. For your dev environment, create:

- **1 VPC** — e.g. CIDR `10.0.0.0/16` (gives you 65,536 IP addresses to play with)
- **1 private subnet** (`10.0.1.0/24`) — target home for SQL Server EC2s in production. Private = no direct internet access.
- **1 public subnet** (`10.0.3.0/24`) — where the EC2 microservice lives. It needs internet to pull packages.
- **1 Internet Gateway** — lets the public subnet reach the internet.

**PoC note:** during the proof-of-concept phase, SQL Server EC2s sit in the *public* subnet (with public IPs) so we can bootstrap them and manage them over WinRM HTTPS. The private subnet exists in Terraform but is unused. This is a PoC trade-off, not the target design. Once the dev → test → prod pipeline is working end-to-end, the move-SQL-to-private-subnet-and-access-via-bastion-or-VPN step is a known follow-up.

No NAT gateway is needed in either layout for now.

### 3.2 Terraform — VPC Module (Starter)

```hcl
# terraform/modules/vpc/main.tf

resource "aws_vpc" "main" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${var.env}-vpc" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = "${var.region}a"
  tags = { Name = "${var.env}-private" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  tags = { Name = "${var.env}-public" }
}

# Internet gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.env}-igw" }
}

# Public route table — routes internet traffic through the IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.env}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private route table — takes ownership of the VPC's default RT so main = private (safe default)
resource "aws_default_route_table" "private" {
  default_route_table_id = aws_vpc.main.default_route_table_id
  tags                   = { Name = "${var.env}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_default_route_table.private.id
}
```

**Why `aws_default_route_table` for the private RT?**

When AWS creates a VPC, it auto-creates one route table and flags it as `main`. The main RT is the fallback for any subnet you forget to explicitly associate. Best practice is to make `main = private` so a forgotten subnet defaults to having no internet access (safe), rather than `main = public` where a forgotten subnet could silently become internet-facing.

Using `aws_default_route_table` takes ownership of the auto-created RT and configures it as your private RT — one fewer resource than creating a brand-new private RT and leaving the auto-created one orphaned.

The module also has `variables.tf` (declares `env`, `region`, `cidr`, `public_subnet_cidr`, `private_subnet_cidr`) and `outputs.tf` (exposes `vpc_id`, `vpc_cidr`, `public_subnet_id`, `private_subnet_id`).

**The dev environment calls the module like this:**

```hcl
# terraform/dev/main.tf
module "vpc" {
  source              = "../modules/vpc"
  env                 = var.env
  region              = var.region
  cidr                = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.3.0/24"
  private_subnet_cidr = "10.0.1.0/24"
}
```

To deploy: `cd terraform/dev && terraform init && terraform plan && terraform apply`

### 3.3 Two SQL Server Instances on EC2

In a real enterprise stack, two SQL Server instances often serve different roles — typically an OLTP primary and a reporting / secondary. For PoC, the current Terraform calls the module twice with placeholder names `sql_live` and `sql_test` (resulting in instances `dev-live` and `dev-test`). Revisit the naming when you commit to a final pattern (primary/reporting, primary/secondary, etc.).

**Why we are not using AWS License Included AMIs:**

AWS does not offer a free License Included AMI for SQL Server *Developer* edition — the License Included options are Express (too limited for realistic learning), Standard, Enterprise, or Web (all metered hourly). To stay within free-tier compute and still run an edition that mirrors prod (Developer is feature-equivalent to Enterprise), the pattern is:

1. Launch a vanilla Windows Server 2022 AMI (free, included in compute hours)
2. `user_data` silently installs SQL Server 2022 Developer from an ISO staged in S3, driven by a `ConfigurationFile.ini` checked into Git
3. After install, run `scripts/inventory/Apply-SqlBaseline.ps1` against the new instance to apply prod config (sp_configure, trace flags, DBMail set to Disable or RedirectToLocal)
4. For PoC, `t3.micro` is fine — workload is one or two databases with a few hundred rows of dummy data. In a real workplace you'd mirror prod's instance type *family* (e.g. `m5.large` → `m5.large`) so memory/CPU ratios match.

**Install split — what goes where:**

| Layer | Owns | Examples |
|---|---|---|
| `ConfigurationFile.ini` | Invariants of the install itself (`setup.exe` reads this directly) | Features (`SQLENGINE`, `AGENT`), instance name, service accounts, collation, install paths, `SQLSYSADMINACCOUNTS`, security mode |
| PowerShell wrapper | Orchestration around `setup.exe` | Mount/copy the ISO from S3, run `setup.exe /ConfigurationFile=...`, wait for completion, log output, signal success |
| `Apply-SqlBaseline.ps1` (post-install) | Tunable config that drifts from prod | sp_configure values, trace flags, DBMail mode, server-level settings |

The reason for the split: `ConfigurationFile.ini` is what `setup.exe` natively understands and the right place for things that can only be set at install time. Anything that *can* be changed after install belongs in the baseline JSON, where it's diffable against prod via `Inventory-SqlServer.ps1`.

Tradeoff: each `terraform apply` of a destroyed env takes ~30 min while SQL installs. Acceptable because dev/test rebuilds are infrequent (monthly, or after major prod changes). See **Phase C** for when Packer becomes worth adding to short-circuit this.

**Access pattern (PoC):** SQL EC2s sit in the public subnet with public IPs. Admin and automation access uses WinRM over HTTPS (5986) allowlisted from a configured admin CIDR. This is preferred over SSH because it is the standard Windows automation path, has stronger Ansible support, and fits PowerShell-first administration with less friction. RDP is optional break-glass access only if you decide to keep it, and SSM Session Manager remains a valid fallback because the IAM role is already wired up. Production target: private subnet, accessed over WinRM HTTPS through a bastion or VPN.

**PoC security controls for WinRM HTTPS:**
- HTTPS only — never expose unencrypted WinRM
- Allow inbound 5986 only from the fixed admin CIDR
- Use strong admin credentials and avoid broad internet exposure
- Treat certificate bootstrap carefully: self-signed is acceptable for PoC if trust is pinned deliberately, but a proper certificate is better

```hcl
# terraform/modules/sql-server/main.tf — current shape

resource "aws_instance" "sql_server" {
  ami                    = var.windows_ami_id   # vanilla Windows Server 2022
  instance_type          = var.instance_type    # t3.micro for PoC
  subnet_id              = var.subnet_id        # public subnet during PoC; private in prod target
  vpc_security_group_ids = [aws_security_group.sql.id]
  iam_instance_profile   = var.iam_instance_profile  # SSM-enabled role

  # user_data (to be added) will install SQL Server Developer silently from an
  # ISO in S3 using setup.exe /ConfigurationFile=..., then run Apply-SqlBaseline.ps1.

  root_block_device {
    volume_size = var.root_volume_size  # 30 GB for PoC
    volume_type = "gp3"
  }

  # Separate EBS volume for SQL data
  ebs_block_device {
    device_name = "/dev/sdf"
    volume_size = var.data_volume_size
    volume_type = "gp3"
  }

  # Separate EBS volume for SQL log (mirrors prod best practice)
  ebs_block_device {
    device_name = "/dev/sdg"
    volume_size = var.log_volume_size
    volume_type = "gp3"
  }

  tags = { Name = "${var.env}-${var.role}" }
}
```

The dev environment calls this module twice in `terraform/dev/main.tf`. **Free-tier note:** root + data + log = 60 GB per instance × 2 = 120 GB EBS, which exceeds the 30 GB free tier. Either shrink volumes or accept the small overage (~£8/month at gp3 rates) while the PoC is running, then `terraform destroy` between sessions.

A future improvement is to swap the hard-coded AMI ID for a `data "aws_ami"` lookup that pulls the latest Windows Server 2022 base AMI for the region — that way the AMI doesn't drift with regional updates.

**Two-script sync workflow with prod:**

| Script | Direction | Purpose |
|---|---|---|
| `scripts/inventory/Inventory-SqlServer.ps1` | prod → Git | Snapshots prod config to JSON. Re-run periodically; Git diff shows drift. |
| `scripts/inventory/Apply-SqlBaseline.ps1` | Git → dev/test | Brings a dev/test instance in line with the baseline. Supports `-WhatIf`. Refuses to target the source server. |

The apply script intentionally does NOT copy host-specific settings (max memory, MAXDOP, tempdb file sizes) — those scale to the target box. It also does NOT copy logins, linked servers, or databases — those have separate lifecycle concerns covered in Phase A.

**DBMail safety in dev/test:** the apply script's `-DbMailMode` parameter controls behaviour:
- `Disable` (default) — sets `Database Mail XPs` to 0; existing accounts/profiles become inert
- `RedirectToLocal` — recreates accounts/profiles with SMTP rewritten to a local catcher (smtp4dev / MailHog at `localhost:25`); jobs still fire, emails get captured in a UI, never delivered
- `Match` — intentionally not implemented; refuses to silently mirror real SMTP servers into dev/test

### 3.4 Security Groups

Security groups are stateful firewalls. The SQL Server module should allow SQL traffic (1433) from the VPC and WinRM HTTPS (5986) from a configurable admin CIDR (your home IP during PoC). Keep RDP closed unless you explicitly retain it for break-glass access:

```hcl
resource "aws_security_group" "sql" {
  name   = "${var.env}-${var.role}-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 1433
    to_port     = 1433
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]  # SQL only from inside the VPC
  }

  ingress {
    from_port   = 5986
    to_port     = 5986
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]  # WinRM HTTPS only from your admin CIDR (e.g. home IP /32)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

### 3.5 The Dummy Microservice

Use a simple .NET 8 Minimal API (or Node.js Express — pick whichever you know). It should:

- Connect to the primary SQL Server instance and expose `GET /items` (reads from a table)
- Expose `POST /items` (writes to the primary SQL Server)
- Expose `GET /report` (reads from the reporting SQL Server)
- Return JSON — no front end needed.

**.NET 8 Minimal API starter (Program.cs):**

```csharp
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapGet("/items", async (IConfiguration cfg) => {
    using var conn = new SqlConnection(cfg["ConnectionStrings:Primary"]);
    var items = await conn.QueryAsync("SELECT * FROM Items");
    return Results.Ok(items);
});

app.Run();
```

Deploy the microservice to an EC2 instance in the public subnet using a simple bash script or Docker. See Phase 4 (CI/CD) for automated deployment.

### 3.6 Secrets Management

Never hard-code database passwords. Use AWS Secrets Manager:

1. Create a secret in AWS Secrets Manager:
   ```bash
   aws secretsmanager create-secret --name dev/sql/primary --secret-string '{"username":"admin","password":"YourPassword"}'
   ```
2. Grant your EC2 instance an IAM role with `secretsmanager:GetSecretValue` permission
3. In your app, retrieve the secret at startup instead of reading from appsettings.json

**Security rule of thumb:** If a value would be embarrassing to commit to GitHub, it belongs in Secrets Manager (or GitHub Secrets for pipeline variables). This includes: database passwords, API keys, connection strings, and certificates.

### 3.7 Host Prep Before SQL Install

These are the host tasks to complete before touching SQL Server setup. Keep this stage focused on the Windows box itself — not the engine install or post-install SQL tuning.

**Necessary before SQL install:**
- Select the correct Windows version for each role and record the exact AMI ID
- Rebuild the EC2 with the chosen AMI
- Bootstrap secure WinRM HTTPS so Ansible has a standard Windows management path
- Verify the admin access path works from the fixed admin CIDR
- Run Windows first-boot configuration
- Ensure SQL install media is reachable from the host
- Initialize and format extra EBS disks if SQL will use them for data, logs, or tempdb

**Recommended but optional refinements:**
- Rename the host for consistency
- Apply Windows Updates before SQL setup
- Keep RDP disabled entirely unless you want explicit break-glass access
- Move SQL paths off `C:` immediately instead of deferring that split

**Automation split:**
- EC2 `user_data`: bootstrap only, just enough to enable secure remote automation
- Ansible: first-boot Windows configuration, WinRM hardening, disk prep, prereqs, and later SQL orchestration

---

## Phase 2 — Test Environment on AWS

*Weeks 3–4*

The test environment is structurally identical to dev but completely isolated. The goal is to catch bugs before they reach production.

### 4.1 Isolate with Separate Terraform State

Copy the dev Terraform folder to test/ and change the `env` variable to "test". Each folder has its own `terraform.tfstate` file — they cannot interfere with each other.

```hcl
# terraform/test/main.tf
module "vpc" {
  source = "../modules/vpc"
  env    = "test"
  cidr   = "10.1.0.0/16"  # Different CIDR from dev (10.0.x.x)
  ...
}

module "sql_live" {
  source = "../modules/sql-server"
  env    = "test"
  role   = "live"
  ...
}

module "sql_test" {
  source = "../modules/sql-server"
  env    = "test"
  role   = "test"
  ...
}
```

### 4.2 Environment Promotion Strategy

Code should move through environments in one direction only: Dev → Test → Production. Never deploy directly to test or prod from your local machine once CI/CD is set up.

| Trigger | What deploys where |
|---|---|
| Push to main branch | Deploys automatically to Dev |
| Merge pull request / tag | Deploys automatically to Test after Dev passes |
| Manual approval in GitHub | Deploys to Production after Test passes |

### 4.3 Test Data Strategy

A test environment is only useful if it has realistic data. Options:

- **Seed scripts** — a SQL script that populates tables with representative dummy data, run by the CI pipeline after deployment.
- **Anonymised copy of production data** — more realistic but requires a process to strip PII (personal data). A good Phase 2 goal once the basics work.

Start with seed scripts — simpler and sufficient for learning.

---

## Phase 3 — Production Environment: On-Premises

*Weeks 4–5*

On-premises (on-prem) means the servers physically sit in your office, data centre, or server room rather than in the cloud. Your production setup will mirror what many enterprises run today.

### 5.1 What You Need (Hardware / VMs)

| Server / VM | Purpose & recommended spec for learning |
|---|---|
| sql-prod-primary | Windows Server 2022 + SQL Server 2022. Min: 4 vCPU, 8 GB RAM, 100 GB disk. |
| sql-prod-reporting | Windows Server 2022 + SQL Server 2022. Same spec. Can be a VM on the same host for learning. |
| app-prod-01 | Windows Server 2022 or Ubuntu 22 LTS for the microservice. 2 vCPU, 4 GB RAM. |

If you do not have physical servers, you can simulate on-prem using a local Hyper-V or VirtualBox setup, or use a cheap VPS (e.g. Hetzner, OVH) as a stand-in.

### 5.2 Connecting On-Prem to AWS (Site-to-Site VPN)

Your microservice on-prem needs to talk to nothing in AWS for production — but your CI/CD pipeline does need to reach the on-prem app server to deploy. An AWS Site-to-Site VPN creates an encrypted tunnel:

```
# High-level steps (Terraform or AWS Console)
1. Create a Virtual Private Gateway in your AWS VPC
2. Create a Customer Gateway pointing at your on-prem public IP
3. Create the Site-to-Site VPN Connection linking the two
4. Download the VPN config file from AWS and apply it to your on-prem router
   (pfSense, Windows RRAS, or a dedicated VPN appliance)
5. Add a route in your VPC route table for your on-prem subnet via the VGW
```

### 5.3 SQL Server Setup on Windows Server

1. Install Windows Server 2022 — use the Evaluation edition (free for 180 days) for learning.
2. Install SQL Server 2022 — Developer edition is free for non-production use.
3. Enable the SQL Server Browser service and TCP/IP protocol in SQL Server Configuration Manager.
4. Open firewall port 1433 for inbound TCP, restricted to your app server's IP only.
5. Create a SQL login for your microservice with least-privilege permissions (SELECT, INSERT, UPDATE on specific databases only).
6. Enable SQL Server Agent for scheduled ETL jobs (mirrors your real workplace pattern).

### 5.4 Firewall & Network Security Rules

On-prem network security is typically enforced at the router/firewall level. Key rules to configure:

- App server → SQL Primary: allow TCP 1433 only
- App server → SQL Reporting: allow TCP 1433 only
- Block all direct inbound internet access to SQL Server instances
- Allow inbound SSH or RDP from your admin machine only, on a non-default port if possible
- Allow inbound from the GitHub Actions IP range on port 22 (SSH) or 443 (for deployment agents)

**GitHub Actions → On-Prem deployment options:**

- **Option A: Self-hosted GitHub Actions runner** — install a small agent on your on-prem app server. The runner polls GitHub and executes jobs locally. No inbound firewall changes needed. *This is the recommended approach.*
- **Option B: SSH deployment** — GitHub Actions SSHes into the app server and runs deploy commands. Requires port 22 open to GitHub's IP ranges.

For production, Option A (self-hosted runner) is far more common and secure.

---

## Phase 4 — CI/CD with GitHub Actions

*Weeks 5–6*

GitHub Actions is the glue that connects your code repository to all three environments. Every time a developer pushes code, the pipeline takes over.

### 6.1 How GitHub Actions Works

| Concept | Explanation |
|---|---|
| Workflow | A YAML file in `.github/workflows/`. Each file is one workflow (e.g. `deploy.yml`). |
| Trigger (`on:`) | The event that starts the workflow — e.g. a push, a pull request merge, or a manual button. |
| Job | A group of steps that run on the same machine (runner). Jobs can run in parallel or in sequence. |
| Step | A single command or pre-built Action (e.g. checkout code, build .NET app, run tests). |
| Runner | The machine that executes the job. GitHub provides hosted runners (Ubuntu, Windows). You can also use self-hosted runners on your own server. |
| Environment | A named target (dev, test, prod) that can have protection rules — e.g. require a human to approve before deploying. |
| Secret | An encrypted variable stored in GitHub Settings → Secrets. Injected into workflows as environment variables. |

### 6.2 Your Pipeline Design

This pipeline runs on every push to the main branch. It builds, tests, deploys to dev, then waits for promotion to test and prod.

```
Push to main
    │
    v
[build-and-test]  -- runs on GitHub-hosted Ubuntu runner
    │  compile .NET app
    │  run unit tests
    │  publish build artifact
    │
    v
[deploy-dev]  -- runs on GitHub-hosted runner, deploys to EC2 dev
    │  download artifact
    │  SSH to EC2 / push Docker image
    │  run smoke test (GET /health)
    │
    v
[deploy-test]  -- waits for deploy-dev to succeed
    │  same steps, targets EC2 test
    │
    v
[deploy-prod]  -- requires manual approval (GitHub Environment protection)
       runs on SELF-HOSTED runner on your on-prem app server
       pulls artifact + restarts the Windows service / Linux daemon
```

### 6.3 The Workflow File

```yaml
# .github/workflows/deploy.yml
name: Build and Deploy

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'
      - name: Build
        run: dotnet build app/ --configuration Release
      - name: Test
        run: dotnet test app/ --no-build --configuration Release
      - name: Publish
        run: dotnet publish app/ -c Release -o ./publish
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: app-build
          path: ./publish

  deploy-dev:
    needs: build
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/download-artifact@v4
        with: { name: app-build, path: ./publish }
      - name: Deploy to Dev EC2
        run: |
          echo "${{ secrets.DEV_SSH_KEY }}" > key.pem && chmod 600 key.pem
          rsync -avz -e "ssh -i key.pem" ./publish/ \
            ec2-user@${{ secrets.DEV_EC2_HOST }}:/opt/myapp/
          ssh -i key.pem ec2-user@${{ secrets.DEV_EC2_HOST }} \
            "sudo systemctl restart myapp"

  deploy-test:
    needs: deploy-dev
    runs-on: ubuntu-latest
    environment: test
    steps:
      # Same as deploy-dev but using TEST_EC2_HOST and TEST_SSH_KEY

  deploy-prod:
    needs: deploy-test
    runs-on: self-hosted       # <-- your on-prem runner
    environment: production    # <-- requires manual approval in GitHub
    steps:
      - uses: actions/download-artifact@v4
        with: { name: app-build, path: C:\deployments\myapp }
      - name: Restart service
        run: Restart-Service -Name MyApp
```

### 6.4 Setting Up GitHub Secrets

Go to your GitHub repo → Settings → Secrets and variables → Actions. Add:

| Secret name | Value |
|---|---|
| DEV_EC2_HOST | Public IP or DNS of your dev EC2 instance |
| DEV_SSH_KEY | Contents of the .pem private key for SSH access to dev EC2 |
| TEST_EC2_HOST | Public IP or DNS of your test EC2 instance |
| TEST_SSH_KEY | Contents of the .pem private key for SSH access to test EC2 |
| DEV_DB_PASSWORD | SQL Server password for dev (used by app at runtime) |
| TEST_DB_PASSWORD | SQL Server password for test |

### 6.5 Setting Up a Self-Hosted Runner (On-Prem)

1. In GitHub, go to Settings → Actions → Runners → New self-hosted runner.
2. Choose Windows or Linux depending on your on-prem app server OS.
3. Follow the on-screen commands to download and register the runner agent.
4. Install it as a service so it starts automatically: `./svc.sh install && ./svc.sh start` (Linux) or `run.cmd` (Windows initial setup).

The runner will appear as Online in GitHub. Jobs targeting `runs-on: self-hosted` will now execute on your on-prem machine.

### 6.6 Production Approval Gates

Protect your production environment from accidental deploys:

1. Go to GitHub → Settings → Environments → production
2. Enable **Required reviewers** and add yourself (or a teammate)
3. When the pipeline reaches deploy-prod, it pauses and sends you an email
4. You review the changes in GitHub, then click **Approve** — the deploy proceeds

This is exactly how enterprise pipelines work. Most companies require 1–2 human approvals before any deployment hits production. Some also require a passing test report, a Change Advisory Board (CAB) ticket, or a maintenance window. GitHub Environments + Required Reviewers gives you the same mechanism for free.

---

## Phase 5 — End-to-End: Your First Full Deploy

*Week 6*

Walk through this sequence to validate everything is wired up correctly:

1. **Make a small change** to the microservice — e.g. add a new endpoint `GET /version` that returns the app version string.
2. **Commit and push to main:** `git add . && git commit -m 'add version endpoint' && git push`
3. **Open GitHub Actions** — watch the build-and-test job run. Check the logs for any compile or test failures.
4. **Watch deploy-dev run.** Once complete, curl the dev URL: `curl http://<dev-ec2-ip>/health` to confirm it is alive.
5. **Watch deploy-test run.** Test the same endpoint against your test EC2 IP.
6. **Receive the approval email** for deploy-prod. Open GitHub, review, approve.
7. **The self-hosted runner** on your on-prem app server runs the deployment steps.
8. `curl http://<on-prem-app-ip>/health` — the response should say the new version.
9. **Connect to each SQL Server instance** with SSMS and confirm the app can still read/write data.

### If something goes wrong

- Check the **GitHub Actions job logs** first — they are usually very specific about what failed.
- If the app starts but cannot connect to SQL Server: check the security group (port 1433), check the connection string secret, and verify the EC2 instance's IAM role has Secrets Manager access.
- If the self-hosted runner is offline: RDP/SSH into the on-prem server and check the runner service is running.
- Terraform errors: run `terraform plan` first to preview changes before `apply`.

---

## 7. Next Steps & Further Learning

Once the fundamentals are solid, explore these topics to get closer to enterprise-grade:

| Topic | Why it matters |
|---|---|
| Terraform Remote State (S3 + DynamoDB) | Share Terraform state safely across a team; prevent concurrent applies corrupting infrastructure. |
| SQL Server Always On Availability Groups | Enterprise HA/DR pattern — exactly what your workplace likely uses for the two SQL Server instances. |
| Docker + Amazon ECS / EKS | Run the microservice in a container rather than directly on EC2. Easier rollbacks and scaling. |
| Monitoring: AWS CloudWatch + Grafana | Dashboards and alerts for CPU, memory, query latency, and error rates. |
| Database Migrations in CI/CD | Use Flyway or Liquibase to apply schema changes automatically as part of the pipeline — the safest way to evolve SQL Server schemas. |
| Branch-based environments | Spin up a temporary cloud environment for each feature branch, then destroy it when the PR is merged. Common in modern teams. |
| SAST / Security Scanning | Add a step in GitHub Actions to scan for vulnerabilities: dotnet-security-audit, Snyk, or Dependabot. |

### Recommended Resources

- **AWS Free Tier overview** — aws.amazon.com/free (understand what is free before you accidentally spend money)
- **Terraform Getting Started** — developer.hashicorp.com/terraform/tutorials/aws-get-started
- **GitHub Actions Quickstart** — docs.github.com/en/actions/quickstart
- **Microsoft Learn: SQL Server on Azure** — learn.microsoft.com (search 'SQL Server on Azure')
- **Book:** *The DevOps Handbook* by Kim, Humble, Debois & Willis — the best conceptual foundation for why CI/CD exists

---

## Phase A — SQL Server Source Control Strategy

*Foundational*

Getting your SQL Server objects into Git is one of the highest-value things you can do, and also one of the most mishandled. This section covers a pragmatic approach for an existing production environment with legacy objects your team doesn't want to fully catalogue upfront.

### A.1 The Three-Bucket Approach

Rather than a binary "in Git" vs "not in Git" split, use three categories during the transition period:

| Bucket | What it means & how it is deployed |
|---|---|
| **Managed** | In Git under `managed/`. CI/CD pipeline deploys it. Git is the source of truth. Any change goes through a pull request. |
| **Legacy-tracked** | Scripted into `legacy/` in Git as a read-only baseline snapshot. Not CI/CD deployed. Dev is built from it so it stays in sync with prod without a nightly copy. |
| **Legacy-untracked** | Confirmed dead objects. Not scripted, not in Git. Must be verified via dependency queries AND filesystem scan before exclusion. |

The middle bucket is the key insight. Scripting legacy objects into `legacy/` costs almost nothing and solves two problems at once: dev can be built from Git alone, and you have a baseline to grep against before removing anything.

### A.2 The Add-As-We-Need-It Approach Done Safely

- **Rule 1:** Before touching any object, move it from `legacy/` to `managed/` first. This naturally pulls in everything you actually use.
- **Rule 2:** Set a target date for ending the prod-to-dev nightly sync (typically 2–3 months). Track objects remaining in `legacy/` each sprint.
- **Rule 3:** Before excluding any object as legacy-untracked, run BOTH the SQL metadata queries AND the filesystem scan described in A.4.
- **Rule 4:** Legacy removal is still a proper deployment. Add the object to `legacy/` first, write a drop migration, test in dev, promote through the pipeline.

**Why the prod-to-dev sync is not a permanent problem:**

The nightly or weekly copy of prod to dev is a bridge, not a destination. Once enough objects are in the `legacy/` or `managed/` buckets, dev can be built entirely from Git.

The risk of keeping the sync running too long: developers stop trusting dev, and the discipline of Git-first erodes. Two to three months is a realistic transition window for most teams.

### A.3 Recommended Folder Structure

```
sql/
  databases/
    YourDb1/
      managed/
        migrations/     # numbered schema change scripts (V001__, V002__...)
        procedures/     # one .sql per SP (CREATE OR ALTER PROCEDURE)
        views/
        functions/
        seeds/          # reference/lookup data inserts only
      legacy/
        procedures/     # baseline snapshot, not CI/CD deployed
        views/
        tables/
    YourDb2/ ...
  agent-jobs/
    managed/            # jobs actively maintained
    legacy/             # baseline snapshot of all existing jobs
  ssis/
    packages/           # .dtsx files (scrubbed of passwords)
    configs/            # project parameters (no secrets)
    legacy/             # packages not yet reviewed
  ssrs/
    reports/            # .rdl files
    legacy/             # baseline snapshot
```

### A.4 Dependency Checking — SQL Metadata AND Filesystem

This is the most critical step before removing any object. SQL Server's system views only see T-SQL object-to-object references inside the database engine. They are completely blind to references inside SSIS packages, SSRS reports, application code, and Excel files with embedded queries.

**The uncatalogued SSIS / SSRS problem:**

- `sys.dm_sql_referencing_entities` and `sys.sql_expression_dependencies` do NOT track references inside `.dtsx` or `.rdl` files.
- An SSIS package with an Execute SQL Task calling your stored procedure will not appear in any SQL Server metadata view.
- An SSRS report with a dataset query using your table will also be invisible to these queries.
- If those packages or reports have never been committed to Git, the only way to find them is a filesystem scan.

This is one of the strongest arguments for getting SSIS and SSRS files into Git early — once they are there, dependency checking becomes a simple text search across the repository.

**Step 1: Query SQL Server metadata** (catches T-SQL dependencies only):

```sql
-- What objects reference this one inside the database?
SELECT referencing_schema_name, referencing_entity_name, referencing_class_desc
FROM sys.dm_sql_referencing_entities('dbo.YourObject', 'OBJECT');

-- What does this object depend on?
SELECT referenced_schema_name, referenced_entity_name
FROM sys.sql_expression_dependencies
WHERE referencing_id = OBJECT_ID('dbo.YourObject');

-- Check SQL Agent job steps
SELECT j.name AS job_name, s.step_name, s.command
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE s.command LIKE '%YourObject%';

-- Last execution date (never called = likely dead, but not proof)
SELECT OBJECT_NAME(object_id) AS proc_name,
       last_execution_time, execution_count
FROM sys.dm_exec_procedure_stats
WHERE OBJECT_NAME(object_id) = 'YourObject';
```

**Step 2: Scan the filesystem for SSIS and SSRS references** (catches what SQL metadata misses):

```powershell
# PowerShell: scan ALL .dtsx and .rdl files on the file server for an object name
# Run this against every known SSIS/SSRS file share before removing anything
$objectName = "YourObjectName"
$searchPaths = @(
    "\\fileserver\ssis\",
    "\\fileserver\ssrs\",
    "\\fileserver\reports\"
)

foreach ($path in $searchPaths) {
    Get-ChildItem -Path $path -Recurse -Include '*.dtsx','*.rdl','*.rsd' |
    Select-String -Pattern $objectName -SimpleMatch |
    Select-Object Path, LineNumber, Line |
    Format-Table -AutoSize
}

# Also search your application code repository if accessible
# git grep 'YourObjectName' -- '*.cs' '*.vb' '*.sql'
```

**Step 3:** Only after both steps return no references is it safe to mark an object as legacy-untracked or proceed with removal.

### A.5 Scripting the Baseline with dbatools

dbatools is a free PowerShell module that scripts an entire SQL Server instance in minutes. Run this once against production to populate the `legacy/` folders.

```powershell
Install-Module dbatools -Scope CurrentUser

# Script all stored procedures to individual files
Export-DbaScript -SqlInstance prod-sql-01 -Database YourDb1 \
  -ScriptingOption StoredProcedures \
  -Path .\sql\databases\YourDb1\legacy\procedures\

# Script all SQL Agent Jobs
Export-DbaScript -SqlInstance prod-sql-01 \
  -ScriptingOption Jobs \
  -Path .\sql\agent-jobs\legacy\

# Script all tables (schema reference only)
Export-DbaScript -SqlInstance prod-sql-01 -Database YourDb1 \
  -ScriptingOption Tables \
  -Path .\sql\databases\YourDb1\legacy\tables\
```

Commit the entire `legacy/` output as a single baseline commit: `'baseline: initial prod snapshot [unmanaged]'`. This is your historical reference — the pipeline never deploys it.

### A.6 Deploying Stored Procedures via GitHub Actions

Managed stored procedures use `CREATE OR ALTER` — they are idempotent, so the pipeline simply replays all of them on every deploy. No migration tracking needed for SPs.

```yaml
# .github/workflows/deploy-sql.yml
name: Deploy SQL Objects

on:
  push:
    branches: [main]
    paths: ['sql/**']

jobs:
  deploy-dev:
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: azure/sql-action@v2
        with:
          connection-string: ${{ secrets.DEV_SQL_CONNECTION_STRING }}
          path: './sql/databases/YourDb1/managed/procedures/*.sql'
          arguments: '-b'

  deploy-prod:
    needs: [deploy-dev]
    runs-on: self-hosted
    environment: production
    steps:
      - uses: actions/checkout@v4
      - name: Deploy SPs to Prod
        run: |
          Get-ChildItem .\sql\databases\YourDb1\managed\procedures\*.sql |
          ForEach-Object {
            Invoke-Sqlcmd -ServerInstance 'prod-sql-01' -Database 'YourDb1' \
              -InputFile $_.FullName -Username $env:SQL_USER -Password $env:SQL_PASS
          }
        env:
          SQL_USER: ${{ secrets.PROD_SQL_USER }}
          SQL_PASS: ${{ secrets.PROD_SQL_PASS }}
```

**Schema migrations vs stored procedure deploys:**

- Stored procedures use `CREATE OR ALTER` and are always safe to re-run.
- Schema changes (`CREATE TABLE`, `ALTER TABLE`) are NOT idempotent and need numbered migration scripts tracked by Flyway or DbUp.
- **Rule:** if running the script twice would cause an error, it needs migration tracking.

---

## Phase B — Claude Code via AWS Bedrock on Dev

*Dev Enhancement*

Claude Code is an AI coding assistant that runs in the terminal and can read, write, and reason about your codebase. By routing it through AWS Bedrock instead of the direct Anthropic API, everything stays inside your AWS account: unified billing, IAM access control, and no separate API key management.

### Why Bedrock instead of the direct API?

- **Consolidated AWS billing** — Bedrock usage appears on the same invoice as your EC2 costs.
- **IAM-controlled access** — grant or revoke Claude access via IAM policies, the same way you manage all other AWS permissions.
- **No separate API keys to rotate** — EC2 instances with the right IAM role authenticate automatically via instance metadata.
- **Data residency** — requests stay within your chosen AWS region.
- **Environment isolation** — easy to restrict Bedrock access to dev only via IAM, preventing AI-assisted changes from reaching test or prod.

### B.1 Enable Claude Models in Bedrock

1. Open the AWS Console and navigate to **Amazon Bedrock**.
2. Go to **Model access** (left sidebar) and request access to the Anthropic Claude models. Claude Sonnet is the recommended default for coding tasks.
3. Approval is usually automatic and takes under five minutes.

Note the Bedrock model ID — it uses the format: `anthropic.claude-sonnet-4-5-20251001-v1:0` (different from the direct API ID). The exact IDs appear in the Model access page once enabled.

### B.2 IAM Permissions (Terraform)

```hcl
# terraform/modules/ec2/main.tf
# Only create in dev — test and prod instances do not get Bedrock access

resource "aws_iam_role_policy" "bedrock_access" {
  count = var.env == "dev" ? 1 : 0
  name  = "${var.env}-bedrock-claude-access"
  role  = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = ["arn:aws:bedrock:*::foundation-model/anthropic.*"]
    }]
  })
}
```

### B.3 Install and Configure Claude Code on the Dev EC2 Instance

```bash
# Install Node.js 20 and Claude Code
curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo yum install -y nodejs
npm install -g @anthropic-ai/claude-code

# Add to /etc/environment or ~/.bashrc
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=eu-west-2
export ANTHROPIC_MODEL=anthropic.claude-sonnet-4-5-20251001-v1:0  # check Bedrock console for the latest available model ID

# No ANTHROPIC_API_KEY needed.
# AWS credentials come automatically from the EC2 instance IAM role.
```

Verify it works: `cd` into your project directory and run `claude`. It should start without prompting for an API key.

### B.4 Useful Patterns for Your Stack

```bash
# Start Claude Code in your project root
cd ~/devops-learning && claude

# Review a stored procedure
> Review sql/databases/YourDb1/managed/procedures/usp_GetOrders.sql
> and suggest performance improvements or error handling gaps

# Help write Terraform
> Write a Terraform module for an EC2 SQL Server instance
> with a security group allowing only port 1433 from within the VPC

# Generate a dbatools dependency scan script
> Write a PowerShell dbatools script to compare stored procedures
> between prod-sql-01 and dev-sql-01 and list any differences

# Debug a GitHub Actions workflow
> Look at .github/workflows/deploy-sql.yml and explain
> why the deploy-prod job might not trigger after deploy-test
```

---

## Phase C — Packer for Golden AMIs

*Deferred — revisit when dev/test churn justifies it*

AWS does not offer a free License Included AMI for SQL Server Developer edition, so dev/test SQL Server EC2 instances are built from a vanilla Windows Server AMI plus a silent SQL Server install in `user_data`, with settings driven by a JSON snapshot of prod (see `scripts/inventory/Inventory-SqlServer.ps1`).

This works because dev/test SQL Servers are rebuilt periodically — typically monthly, or when a major change lands on prod — not on every code push. A 30-minute SQL install on an infrequent rebuild is acceptable.

### When to revisit Packer

Packer (HashiCorp's image-building tool) builds a pre-baked AMI: vanilla Windows → install SQL Server → apply baseline → snapshot. The output is a versioned AMI ID that Terraform consumes, and EC2 launches drop from ~30 minutes to ~2 minutes.

Add Packer if any of these become true:

| Signal | Why Packer helps |
|---|---|
| Dev/test rebuilds become frequent (weekly+) | The 30-min `user_data` install becomes a real bottleneck |
| You need ephemeral feature-branch environments | Spinning up a fresh DB per PR is only viable with fast launches |
| Multiple engineers each maintaining their own dev env | Shared AMI = consistent baseline, no "works on my machine" |
| Compliance/audit requires immutable, hash-versioned base images | AMIs tied to git commits give you that audit trail |
| You're deploying to multiple AWS regions or accounts | Packer builds once and copies the AMI everywhere |

### What a Packer-based flow would look like

```
Packer (build phase, runs when SQL binaries change — rarely)
  ├── Base: latest Windows Server 2022 AMI
  ├── Install SQL Server 2022 Developer (silent, from S3-hosted ISO)
  ├── Apply baseline (DBMail XPs off, TCP enabled, firewall rules)
  └── Output: ami-0abcd1234... tagged with git commit SHA

Terraform (deploy phase, runs per environment)
  ├── data "aws_ami" pulls latest baked AMI by tag
  ├── EC2 launches in ~2 min instead of 30
  └── user_data still applies env-specific config (memory, MAXDOP, etc.)
```

The split stays the same — invariants in the image, env-specific config in `user_data`. Packer just changes *where* the install step runs.

### Why we are not doing this yet

Adding Packer means a second tool to learn, a second pipeline to maintain (image build vs infrastructure apply), and a separate S3 bucket for SQL Server install media. For a 2–4 instance learning project rebuilt occasionally, the `user_data` approach is simpler and keeps the focus on Terraform + GitHub Actions + SQL fundamentals. Revisit once the rebuild cadence or environment count justifies the extra moving parts.

---

Good luck — the best way to learn this is to break things and fix them.
