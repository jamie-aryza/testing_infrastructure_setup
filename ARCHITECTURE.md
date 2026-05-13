# Architecture and Decisions

This document explains what this project is, the route from PoC to production, and
the architectural decisions that shaped the current shape of the repo. It deliberately
avoids tutorial content (what is a VPC, how to install Terraform) — that lives in the
README. Read this when you want to understand **why** the code looks the way it does.

## What this is

A working dev → test → prod proof of concept for **SQL Server object deployments via
GitHub Actions**, with two SQL Server hosts per environment (live + test roles) and
a .NET microservice. The PoC runs in AWS for dev/test; production targets on-prem
Windows Server. Decisions favour the simplest thing that exercises the real shape of
the pipeline; explicit hardening steps are listed in [PoC vs production target](#poc-vs-production-target).

## Stack

| Layer | Choice | Notes |
|---|---|---|
| Cloud | AWS (dev/test only) | `eu-west-2`, free-tier-conscious |
| On-prem | Windows Server (prod) | Mirrors target enterprise pattern |
| IaC | Terraform | Per-env folders, separate state |
| Windows automation | PowerShell over WinRM HTTPS (5986) | Replaced Ansible — see decisions |
| CI/CD | GitHub Actions | Self-hosted runner for on-prem prod |
| DB | SQL Server 2019 Developer on EC2 | x2 per env: live (OLTP) + test (reporting) |
| App | .NET microservice | Reads live, queries linked test for reporting |

## Topology

| Environment | Where | SQL Servers | App |
|---|---|---|---|
| Dev | AWS | 2x EC2 (public subnet, PoC) | EC2 |
| Test | AWS | 2x EC2 (public subnet, PoC) | EC2 |
| Prod | On-prem | 2x Windows Server | App server on-prem |

The two SQL hosts per environment have a SQL Server linked-server relationship between
them. Dev-live links to dev-test and vice versa, never to prod.

## Phase status

| Phase | What | Status |
|---|---|---|
| 0 - Foundations | AWS, IAM, Terraform basics | Done |
| 1 - Dev infrastructure | VPC, 2x EC2 SQL Server, EBS, security groups, modules | Done |
| 2 - Host bootstrap & prep | WinRM HTTPS, disk format, IAM/SSM | Done |
| 3 - SQL install | Silent install from S3 ISO, post-install baseline | Done (pending re-run after mixed-mode fix) |
| A - SQL source control | Three-bucket managed/legacy strategy | Designed, not yet implemented |
| 4 - GitHub Actions | SQL deployment pipeline, build → test → deploy | Next |
| 5 - Test environment | Second AWS env, promotion gates | Next |
| 6 - Prod on-prem | Windows Server, VPN tunnel, self-hosted runner | Future |
| 7 - End-to-end | Full push-to-deploy across all envs | Future |
| B - Bedrock/Claude | Claude Code via Bedrock on dev EC2 | Deferred |
| C - Packer | Golden AMIs when rebuild cadence justifies it | Deferred |

---

## Configuration framework

The most important decision in this project. SQL Server has many settings; getting the
wrong setting in the wrong place either fails to match prod (silent drift) or has real
external side effects (spamming users, connecting to prod from dev/test).

Settings fall into four buckets. The guiding test:

- **Can `setup.exe` set it? Does it not differ between dev/test/prod?** → ini file
- **Must it differ from prod to avoid external side effects?** → environment config
- **Pure engine tuning, no external side effects, should match prod?** → inventory + ProdSync
- **Depends on actual host hardware?** → post-install calculation

### Setting ownership

| Setting | Where it lives | Why |
|---|---|---|
| Features, collation, file paths, service accounts, FileStream | `ConfigurationFile.ini` (hand-crafted) | Install-time; match prod manually |
| Auth mode (`SECURITYMODE=SQL`) | ini — **deviation from prod** | GHA runners need SQL auth; prod is Windows-only |
| Memory/MAXDOP initial values | ini (safe boot-time defaults) | Post-install overrides with host-sized values |
| DBMail | Env config (`DbMailMode` in PostInstall config) | Prod sends to real recipients — dev/test must never replicate |
| SQL Agent alerts/operators | **Not applied** | Would email real people |
| Linked server targets + credentials | Env config (PostInstall config + Terraform outputs) | Prod links to prod data; dev/test link to each other |
| sp_configure tuning, trace flags | Inventory JSON + ProdSync | Pure engine tuning; too many to maintain manually |
| `gha_deploy` / linked server SQL logins | Post-install HostSpecific (fresh) | Passwords are env-specific |
| Memory, MAXDOP, tempdb sizing | Post-install HostSpecific (calculated) | Prod hardware is completely different |

### File roles

**`ConfigurationFile.live.ini` / `ConfigurationFile.test.ini`** — SQL Server unattended
install config. `setup.exe` reads it once; cannot be changed without reinstalling.
Hand-crafted; sync prod-equivalent settings manually using the inventory JSON as reference.
Lines marked "DEVIATION FROM PROD" are intentional dev/test overrides.

**`PostInstall.Live.Config.psd1` / `PostInstall.Test.Config.psd1`** — per-role environment
config. Holds `BaselinePath`, `DbMailMode`, `GhaDeployLoginName`, `TargetDatabase`, and
linked-server entries (`LinkedServerName`, `LinkedServerLogin`, `LinkedServerRemoteTerraformOutput`).
Updated automatically by `Inventory-SqlServer.ps1 -Environment Live|Test` for the
baseline path; user-editable fields are preserved across re-runs.

**`Inventory-SqlServer.ps1` JSON output** — captures prod runtime settings the ini cannot
hold. Only `sql-sp-configure.json` and `sql-trace-flags.json` are applied automatically
(by ProdSync). `dbmail.json`, `logins.json`, `linked-servers.json` are reference/audit
only — they describe prod's setup but are not replayed onto dev/test.

**`Invoke-PostInstall.ps1`** — runs over WinRM HTTPS. Modes:
- `-Mode ProdSync` — sp_configure + trace flags from inventory JSON
- `-Mode HostSpecific` — calculates memory/MAXDOP/tempdb; creates `gha_deploy` and linked-server logins; sets up the linked server pointing at the other host
- `-Mode All` (default) — both

### Why DBMail and linked servers are env config, not prod-sync

Prod has real SMTP accounts and real linked-server targets. Blindly copying either to
dev/test would spam users or expose dev/test to prod data. Instead:

- **DBMail** is always explicitly `Disable` or `RedirectToLocal` (to smtp4dev/MailHog).
  `Match` is intentionally not implemented.
- **Linked servers** on dev/test point at the other host within the same environment
  (dev-live ↔ dev-test), never at prod. Targets come from Terraform outputs; credentials
  are a dedicated `ls_remote_query` SQL login created fresh on each host.

The general principle: **anything in prod that sends data or connects to an external
system is environment config**, not prod-sync.

---

## Key architectural decisions

### Why WinRM HTTPS, not Ansible or SSH

Ansible was trialled for Windows host prep but dropped: control-node overhead on Windows
is high, and SQL orchestration already lives naturally in PowerShell + dbatools. WinRM
HTTPS is the standard Windows remoting protocol, and PowerShell remoting matches the
admin machine's natural tooling. SSH on Windows works but loses the PowerShell module
ecosystem that the SQL scripts already depend on.

### Why vanilla Windows AMI + silent SQL install (not License Included)

AWS has no free License Included AMI for SQL Server **Developer** edition. License
Included options are Express (too limited), Standard, Enterprise, or Web — all metered
hourly. Developer is feature-equivalent to Enterprise and free for non-production use,
so the pattern is: vanilla Windows AMI → `user_data` bootstrap → silent SQL install
from an ISO in S3 → post-install configuration. ~25–30 minutes per host install; fine
because dev/test rebuilds are infrequent (~monthly).

### Why `ConfigurationFile.ini` is hand-crafted, not generated from prod inventory

Considered generating the ini from inventory output, but rejected for the PoC:
- Most ini settings are environment-fixed (file paths, service accounts, network) and
  don't come from prod
- The few prod-derived settings (collation, features, filestream) are stable enough that
  manual maintenance is fine
- Adding ini-generation introduces complexity for marginal benefit

The inventory script still adds clear value for sp_configure + trace flags, which would
be tedious to enumerate manually.

### Why mixed-mode SQL auth on dev/test (`SECURITYMODE=SQL`)

Prod uses Windows authentication only (`LoginMode=1`). Dev/test EC2s deviate because
GitHub Actions runners cannot use Windows auth against a non-domain-joined EC2. The
ini explicitly marks this as `DEVIATION FROM PROD`. The `gha_deploy` SQL login created
post-install authenticates from GHA runners using SQL auth.

### Why SQL hosts sit in the public subnet during the PoC

A private subnet exists in Terraform but is unused. Putting SQL hosts in the public
subnet (with public IPs restricted to a fixed admin CIDR for WinRM HTTPS 5986) keeps
the PoC simple — no bastion, no VPN. Documented as a deliberate trade-off; production
target moves the hosts to the private subnet behind a bastion or VPN.

### Why PowerShell-first, not a unified config tool

Tried Ansible. The PowerShell + dbatools workflow on a Windows admin machine has a
shorter setup, fewer moving parts, and matches the SQL ecosystem natively. Trade-off:
PowerShell doesn't have Ansible's declarative state model, so scripts use explicit
idempotency checks (e.g. `if not exists → create`).

### Why install runs via scheduled task as SYSTEM, not Start-Process

SQL Server `setup.exe` calls DPAPI (`ProtectedData.Protect`) when serialising secure
strings to its log datastore. DPAPI requires the calling user's profile key store,
which is unavailable in a non-interactive WinRM session — `Start-Process` produces
exit code `-2146233079` (Access is denied). Running setup as a scheduled task under
SYSTEM gives it the SYSTEM DPAPI key store, which is always accessible.

### Why `gha_deploy` is created post-install, not via the ini

`SQLSYSADMINACCOUNTS` in the ini only accepts existing Windows accounts. SQL logins
must be created after install via `New-DbaLogin`. Password is prompted once and stored
as a GHA secret; never written to disk or Git.

---

## SQL source control: the three-bucket strategy

For migrating an existing prod database into Git without forcing an upfront catalogue
of every object. Three categories during the transition:

| Bucket | What it means |
|---|---|
| **Managed** | In Git under `managed/`. CI/CD deploys it. Git is the source of truth. PRs required for changes. |
| **Legacy-tracked** | Scripted into `legacy/` as a read-only baseline snapshot. Not deployed by CI/CD. Dev is built from it so it stays in sync with prod without a nightly copy. |
| **Legacy-untracked** | Confirmed dead objects. Not scripted. Verified via both SQL metadata queries **and** filesystem scan before exclusion. |

**Migration rules:**
- Before touching any object, move it from `legacy/` to `managed/` first
- Set a transition deadline for ending the prod-to-dev sync (typically 2–3 months)
- Before excluding any object, run both `sys.dm_sql_referencing_entities` AND a
  filesystem scan of `.dtsx` / `.rdl` / app-code repositories (SQL metadata is blind
  to SSIS/SSRS references)
- Legacy removal is still a proper deployment — add a drop migration, test in dev, promote

Folder structure for each database: `sql/databases/<db>/managed/{migrations,procedures,views,functions,seeds}` and `sql/databases/<db>/legacy/{procedures,views,tables}`. Same split for `agent-jobs/`, `ssis/`, `ssrs/`.

Stored procedures use `CREATE OR ALTER` (idempotent — pipeline replays all on every
deploy). Schema changes use numbered migrations (Flyway or DbUp). **Rule:** if running
the script twice would cause an error, it needs migration tracking.

---

## PoC vs production target

| Area | PoC (current) | Production target |
|---|---|---|
| SQL EC2 placement | Public subnet, public IPs | Private subnet, no public IP |
| Admin access | WinRM HTTPS (5986) from fixed admin CIDR | WinRM HTTPS via bastion or site-to-site VPN; or SSM Session Manager |
| SQL ISO delivery | Pre-signed S3 URL passed into WinRM session | EC2 downloads via IAM role (`aws s3 cp`); AWS CLI baked into AMI |
| SQL auth mode | Mixed (dev/test deviation) | Windows-only on prod, mixed on dev/test |
| `ConfigurationFile.ini` | Hand-crafted | Could become generated from prod inventory once inventory captures all install-time settings |
| AMI | Vanilla Windows + 30-min install | See "Deferred: Packer" |
| RDP | Gated by `enable_rdp` var, default off | Removed or kept as emergency break-glass only |
| Instance type | `t3.micro` | Mirror prod instance type family (memory/CPU ratio) |
| Free-tier overage | 120 GB EBS exceeds 30 GB free tier (~£8/month) | Right-size for workload |

## Production rollout: what additionally needs solving

- **VPN tunnel:** AWS Site-to-Site VPN between the AWS VPCs and the on-prem network.
  Virtual Private Gateway + Customer Gateway pointing at on-prem public IP.
- **Self-hosted GitHub Actions runner** on the on-prem app server (preferred over
  GitHub-to-on-prem SSH). Runner polls outbound; no inbound firewall holes needed.
- **Production approval gate** via GitHub Environment protection (Required Reviewers)
  on the `production` environment.
- **Secrets** via AWS Secrets Manager (dev/test app runtime) and GitHub Secrets
  (pipeline variables). Database passwords never in source.
- **Test data strategy:** seed scripts first; anonymised prod data restore later
  (requires a PII-strip step).
- **Monitoring:** CloudWatch + Grafana for query latency / error rates.

---

## Deferred decisions

### Packer for golden AMIs

Not used yet. EC2 launches take ~30 minutes (vanilla AMI + silent SQL install).
Acceptable because dev/test rebuilds are infrequent (~monthly). Revisit when any of
these become true:

| Signal | Why Packer helps |
|---|---|
| Rebuilds become frequent (weekly+) | 30-min install becomes a bottleneck |
| Ephemeral feature-branch envs needed | Only viable with ~2-min launches |
| Multiple engineers with own dev envs | Shared AMI = consistent baseline |
| Compliance requires immutable, hash-versioned images | AMIs tied to git commits give audit trail |
| Multi-region or multi-account deploys | Packer builds once, copies the AMI |

The install split stays the same — invariants in the image, env-specific config in
post-install. Packer just moves *where* the install runs.

### Claude Code via Bedrock on dev EC2

Routes Claude through AWS Bedrock instead of the direct Anthropic API: unified AWS
billing, IAM access control, no separate key rotation, data residency in chosen region.
Useful but not on the critical path for the SQL deployment PoC. Implementation is
straightforward (IAM role with `bedrock:InvokeModel`, `npm install -g @anthropic-ai/claude-code`,
set `CLAUDE_CODE_USE_BEDROCK=1` and `ANTHROPIC_MODEL=anthropic.claude-...`).

### Database migrations framework (Flyway / DbUp)

Stored procedures with `CREATE OR ALTER` need no framework. Schema changes do. Pick
Flyway or DbUp when the first non-idempotent migration is needed. Until then, the
pipeline just replays all SP scripts.

### Always On Availability Groups

The two SQL hosts per environment are currently independent with a linked-server
relationship. Real prod likely uses Always On AG for HA/DR. Worth a Phase Z once the
pipeline is end-to-end working — adds a witness, listener, and replication topology
that the PoC doesn't need.
