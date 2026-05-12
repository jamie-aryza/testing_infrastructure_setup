# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Purpose

This is a DevOps learning project following a phased roadmap. The goal is to build a full CI/CD pipeline across three environments (Dev, Test, Prod) using AWS, Terraform, GitHub Actions, SQL Server, and a .NET microservice.

## PoC Scope

The current focus is a working dev → test → prod proof of concept for **SQL Server object deployments via GitHub Actions**. Infrastructure choices are deliberately simple and tweakable — production-grade hardening (strict private subnets, VPC endpoints, bastion hosts, SSM-only access, properly sized instance types) is a later phase.

**Current PoC trade-offs:**
- SQL Server EC2s sit in the public subnet with public IPs to allow direct RDP access. Production target: private subnet, accessed via bastion or SSM Session Manager.
- Admin access is via RDP from a fixed admin CIDR allowlisted in the security group. SSM is a valid alternative (the SSM IAM role is already wired up); RDP wins for now on familiarity with SSMS.

## Stack

- **Cloud:** AWS (Dev & Test environments)
- **On-prem:** Windows Server (Prod environment)
- **IaC:** Terraform
- **CI/CD:** GitHub Actions
- **Database:** SQL Server on EC2 (x2 per environment — primary/secondary pattern). No free AWS License Included AMI exists for SQL Server Developer edition, so dev/test use a vanilla Windows Server AMI + silent install of SQL Server Developer. Install is driven by SQL Server's `ConfigurationFile.ini` (feature selection, instance name, service accounts, file paths) wrapped in a PowerShell script that pulls the ISO from S3, runs `setup.exe /ConfigurationFile=...`, then post-applies the JSON baseline exported from prod.
- **App:** .NET microservice on EC2 (cloud) or app server (on-prem)

## Project Structure

```
terraform/
  dev/              # Dev environment (providers.tf, variables.tf, main.tf)
  test/             # Test environment (same structure as dev)
  modules/
    vpc/            # VPC, subnets, IGW, route tables
    sql-server/     # EC2 SQL Server module (AMI, EBS, security group)
scripts/
  inventory/        # PowerShell + dbatools scripts to capture prod SQL config as JSON,
                    # so dev/test can be built to match. Outputs go to
                    # infrastructure-baseline/<server>/ and are committed to Git.
infrastructure-baseline/
  <server-name>/    # JSON snapshot of prod (sp_configure, trace flags, dbmail, etc.)
app/
  .github/
    workflows/      # GitHub Actions CI/CD pipelines
```

## Terraform Usage

```bash
cd terraform/dev
terraform init      # first time — downloads providers, initialises modules
terraform plan      # preview changes
terraform apply     # deploy to AWS
```

- Dev and test have separate state files — they cannot interfere with each other
- Modules in `terraform/modules/` are reusable across environments
- AWS provider is configured for `eu-west-2` (London)
- Instance type is `t3.micro` (free-tier eligible). Workload is light — one or two databases with a few hundred rows of dummy data — so 1 GB RAM is sufficient for learning purposes.

## Network Layout

- One public subnet
- One private subnet (created but not yet used — SQL EC2s currently live in the public subnet during PoC; will move to private once SSM/bastion access is in place)
- Security groups restrict SQL (1433) to VPC internal traffic and RDP (3389) to the configured admin CIDR

## Environment Layout

| Environment | Where | SQL Server | App |
|---|---|---|---|
| Dev | AWS | 2x EC2 (private subnet) | EC2 (public subnet) |
| Test | AWS | 2x EC2 (private subnet) | EC2 (public subnet) |
| Prod | On-prem | 2x Windows Server | App server |

## SQL Server Build Strategy

- **Source of truth:** prod (on-prem). Dev/test drift toward prod, never the other way.
- **Capture (prod → Git):** `scripts/inventory/Inventory-SqlServer.ps1` (dbatools) exports prod config to JSON in `infrastructure-baseline/<server>/`. Re-run periodically; Git diff = config drift.
- **Apply (Git → dev/test):** `scripts/inventory/Apply-SqlBaseline.ps1` reads those JSONs and brings a target instance in line. Supports `-WhatIf`. Refuses to run against the baseline source. Skips host-specific settings (memory, MAXDOP, tempdb sizes) — those scale to the target box, not prod.
- **DBMail in dev/test:** the apply script's `-DbMailMode` controls behaviour. `Disable` (default) sets DBMail XPs to 0. `RedirectToLocal` recreates accounts/profiles with SMTP rewritten to a local catcher (smtp4dev / MailHog). `Match` is intentionally not implemented — too risky to silently mirror real SMTP servers into dev/test.
- **Rebuild cadence:** dev/test SQL Servers are rebuilt periodically (e.g. monthly), or when a major change lands on prod. Not on every code push.
- **Packer:** deliberately not used yet. See the Packer section in `DevOps_Learning_Roadmap.md` for when it becomes worth adding.
