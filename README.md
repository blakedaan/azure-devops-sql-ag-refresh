# AG Database Refresh Automation

> **Stack:** GitHub (YOUR_ORG org) · Azure DevOps Pipelines · Azure Automation · Hybrid Workers · Managed Identity
> **Purpose:** Fully automated SQL Server Availability Group database refreshes using production backups
> **Source Control:** YOUR_ORG GitHub org repo — ADO Pipelines read from GitHub
> **Environments:** URT (active) · TRIAGE · STG · PROD
> **Backups:** Always sourced from production storage (yourstorageaccount)
> **Auth:** System-assigned Managed Identity — zero plaintext credentials
> **Author:** Your Name | Co-Author
> **Version:** 3.2 | April 2026

---

## How It Works

```
GitHub (YOUR_ORG org)               ← source of truth — all code lives here
    ↓ ADO reads from GitHub
Azure DevOps Pipelines           ← execution engine
    ↓ selects variable group by TargetEnvironment
    ↓ routes to Hybrid Workers
SQL Server VMs (target env)      ← where scripts actually run
    ↓ downloads from
yourstorageaccount (prod)       ← all environments pull backups from prod
```

---

## Repository Structure

```
your-ag-refresh-repo/
├── pipelines/
│   ├── ag-validate.yml    # PR validation — syntax check + secret scan on every PR
│   ├── ag-deploy.yml      # Auto-deploys scripts to Hybrid Workers on merge to main
│   └── ag-refresh.yml     # Manual trigger — runs the AG database refresh
├── scripts/
│   ├── Invoke-AGDatabaseRefresh.ps1   # Main orchestration (9 phases)
│   ├── Download-SqlBackups.ps1        # Phase 0 — download .bak from prod Blob Storage
│   ├── CreateRefreshScript.ps1        # Phase 3 — generate T-SQL restore script
│   ├── DatabaseRefresh.ps1            # Phase 4 — execute restore
│   └── PostRefreshScript.ps1          # Phase 5 — post-restore SQL config
├── sql/
│   └── DatabasePostRestore.sql        # Permissions, config, OAuth, users
├── kql/
│   └── ag-refresh-monitoring.kql.md  # Log Analytics monitoring queries
└── docs/
    ├── runbook.md                     # Full setup and implementation guide
    ├── ado-setup.md                   # Azure DevOps + GitHub connection guide
    └── troubleshooting.md             # Common failures and fixes
```

---

## Pipeline Overview

| Pipeline | Trigger | Purpose |
|---|---|---|
| `ag-validate.yml` | Every PR to main (GitHub) | Syntax check + secret scan — broken scripts cannot merge |
| `ag-deploy.yml` | Merge to main (scripts/sql changed) | Auto-deploys latest scripts to all Hybrid Workers |
| `ag-refresh.yml` | Manual only | Runs the full AG database refresh |

### ag-refresh.yml Stage Flow

```
Stage 1: Validate  → Parameter check + verify backup files exist in prod Blob Storage
Stage 2: Refresh   → Run Invoke-AGDatabaseRefresh.ps1 on primary replica
                     (PROD requires manual approval — all others run immediately)
```

> **Notifications:** Configure via ADO > Project Settings > Notifications
> Build completed > Pipeline = AG Refresh — Run Refresh > send to DBA team email

---

## ADO Variable Groups — One Per Environment

Each environment has its own variable group. The pipeline selects the correct
group automatically based on the `TargetEnvironment` parameter.
All environments currently pull backups from the same prod storage account.

### ag-refresh-config-urt (active)

| Variable | Value | Secret? |
|---|---|---|
| `AUTOMATION_ACCOUNT_NAME` | your-automation-account | No |
| `STORAGE_ACCOUNT_NAME` | yourstorageaccount | No |
| `CONTAINER_NAME` | your-container | No |
| `BACKUP_NAME_PREFIX` | YourPrefix_ | No |
| `SERVICE_CONNECTION` | your-service-connection | No |

### ag-refresh-config-triage (future)

| Variable | Value | Secret? |
|---|---|---|
| `AUTOMATION_ACCOUNT_NAME` | aa-scus-triage-sql-refresh-001 | No |
| `STORAGE_ACCOUNT_NAME` | yourstorageaccount | No |
| `CONTAINER_NAME` | your-container | No |
| `BACKUP_NAME_PREFIX` | YourPrefix_ | No |
| `SERVICE_CONNECTION` | your-service-connection | No |

### ag-refresh-config-stg / ag-refresh-config-prod (future)

Same structure — update `AUTOMATION_ACCOUNT_NAME` to the correct automation account
for that environment when provisioned.

---

## ADO Environments

| Environment | Approval | Status |
|---|---|---|
| `AG-REFRESH-URT` | No approval required | Active |
| `AG-REFRESH-TRIAGE` | No approval required | Future |
| `AG-REFRESH-STG` | No approval required | Future |
| `AG-REFRESH-PROD` | Manual approval required | Future |

---

## ADO Service Connection

| Connection Name | Subscription | Used For |
|---|---|---|
| `your-service-connection` | your-prod-subscription-name | All environments — validates prod backup files |

> All environments pull backups from prod storage. One service connection handles all.
> Created by Alberto (requires Contributor on prod subscription).

---

## Refresh Pipeline Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `AvailabilityGroupName` | Yes | — | Name of the SQL Server AG |
| `DatabaseName` | Yes | YOUR_DATABASE | Database to refresh |
| `BackupDate` | Yes | — | Date of production backup (yyyy-MM-dd) |
| `PrimaryReplica` | Yes | — | Primary replica server name (must match ADO agent name) |
| `SecondaryReplicas` | Yes | — | Comma-separated secondary replica names (no spaces) |
| `TargetEnvironment` | Yes | URT | Selects variable group + approval gate |
| `SeedingTimeoutMinutes` | No | 45 | Seeding monitor timeout |

---

## Execution Flow (9 Phases)

```
Phase 0  Pre-flight checks + download .bak files from prod Blob Storage
Phase 1  Remove database from Availability Group
Phase 2  Drop database on all secondary replicas (parallel)
Phase 3  Generate T-SQL restore script from downloaded .bak files
Phase 4  Restore database on primary replica
Phase 5  Run post-restore SQL configuration (DatabasePostRestore.sql)
Phase 6  Add database back to Availability Group
Phase 7  Monitor automatic seeding
Phase 8  Auto-repair failed replicas (conditional)
Phase 9  Cleanup downloaded backup files
```

---

## Azure Infrastructure

| Component | Name | Subscription |
|---|---|---|
| GitHub Org Repo | YOUR_ORG org / your-ag-refresh-repo | GitHub Enterprise |
| ADO Project | YOUR_ADO_PROJECT | dev.azure.com/YOUR_ADO_ORG |
| ADO Service Connection | your-service-connection | your-prod-subscription-name |
| ADO Agent Pool | your-automation-account | ADO Organization |
| Automation Account (URT) | your-automation-account | your-stg-subscription-name |
| Resource Group (URT) | your-resource-group | your-stg-subscription-name |
| Backup Storage | yourstorageaccount / your-container | your-prod-subscription-name |

---

## Adding a New Environment

1. Provision the Automation Account and Hybrid Workers for the new environment
2. Create a new variable group `ag-refresh-config-<env>` with the correct `AUTOMATION_ACCOUNT_NAME`
3. Create the ADO environment `AG-REFRESH-<ENV>` (add approval gate if PROD)
4. Add the environment to `TargetEnvironment` values in `ag-refresh.yml`
5. Add a new `${{ if }}` block in the variables and environment sections
6. Register the new Hybrid Worker VMs in the ADO agent pool
7. Run the deploy pipeline to push scripts to the new workers

---

## Security Notice

All scripts use Managed Identity for Azure authentication — no stored passwords or keys.
`DatabasePostRestore.sql` contains environment-specific OAuth secrets — managed in the
private YOUR_ORG GitHub org repo only. Never push to any public repository.
