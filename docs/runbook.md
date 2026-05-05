# Runbook Setup Guide

Full implementation guide for the AG Database Refresh Automation platform.
Source control is the YOUR_ORG GitHub org repo. ADO Pipelines reads from GitHub.

For Azure DevOps configuration see [`ado-setup.md`](ado-setup.md).

---

## Part 1: Azure Prerequisites

### Step 1 — Resource Group (URT environment)
```
your-resource-group  (your-stg-subscription-name)
```

### Step 2 — Automation Account (URT environment)
| Setting | Value |
|---|---|
| Name | your-automation-account |
| Subscription | your-stg-subscription-name |
| Resource Group | your-resource-group |
| Managed Identity | System-assigned — ON |

---

## Part 2: Permissions & Security

### Step 3 — RBAC Assignments (URT environment)

| Role | Resource | Subscription |
|---|---|---|
| Reader | your-resource-group | stg-001 |
| Automation Contributor | your-automation-account | stg-001 |
| Monitoring Reader | your-resource-group | stg-001 |
| Storage Blob Data Reader | yourstorageaccount | prod-01 — ask Alberto |

### Step 4 — SQL Authentication
Windows Authentication via Hybrid Worker service account.
- Test/URT: `YOUR_DOMAIN\your_service_account`
- Prod: `YOUR_DOMAIN\svc_DistSysPrd`

---

## Part 3: Hybrid Runbook Workers

### Step 5 — Create Worker Group
```
Azure Portal > your-automation-account > Hybrid Worker Groups
Name: sql-ag-workers
```

### Step 6 — Install Extension on Each SQL VM
Run as Administrator on every replica:

```powershell
Install-Script -Name New-OnPremiseHybridWorker -Force

New-OnPremiseHybridWorker `
    -AutomationAccountName "your-automation-account" `
    -HybridWorkerGroupName "sql-ag-workers" `
    -SubscriptionId "<your-stg-subscription-name-id>" `
    -ResourceGroupName "your-resource-group"
```

### Step 7 — Register as ADO Agents
See [`ado-setup.md`](ado-setup.md) Step 10 for agent registration.
Each VM must appear in both Azure Automation and the ADO agent pool as Online.

---

## Part 4: GitHub + ADO Setup

See [`ado-setup.md`](ado-setup.md) for the complete step-by-step guide.

Key points:
- Code lives in GitHub — ADO reads YAML directly from the repo
- Branch protection configured in GitHub (not ADO)
- One service connection (`your-service-connection`) pointing at prod subscription — created by Alberto
- One variable group per environment — pipeline selects correct group at runtime
- Notifications via ADO email subscription (no Teams webhook required)

---

## Part 5: Running a Refresh

### Pre-Flight Checklist
- [ ] All Hybrid Workers show Online in ADO agent pool
- [ ] AG is HEALTHY — verify in SSMS
- [ ] Production backup exists for target BackupDate in yourstorageaccount
- [ ] H:\\WORKDIR\\AutomatedRefresh\\ is empty on primary replica
- [ ] Latest scripts deployed — check timestamps in H:\\WORKDIR\\Scripts\\
- [ ] Team notified — database unavailable during restore (~45-90 min)

### Running the Refresh
1. ADO > Pipelines > **AG Refresh — Run Refresh** > Run pipeline
2. Fill in parameters:

| Parameter | URT Example |
|---|---|
| Availability Group Name | YOUR_AG_NAME |
| Database Name | YOUR_DATABASE |
| Backup Date | 2026-03-05 |
| Primary Replica | YOUR_SECONDARY_REPLICA_2 |
| Secondary Replicas | YOUR_SQL_SERVER-U02,YOUR_PRIMARY_REPLICA |
| Target Environment | URT |

3. Stage 1 runs immediately — parameter check + backup file count (~2-5 min)
4. Stage 2 executes on the primary replica Hybrid Worker (~45-90 min)
5. PROD only: approval notification sent — approver clicks Approve in ADO
6. Email notification sent on completion or failure (both)

### Expected Duration
| Phase | Duration |
|---|---|
| Stage 1 — Validation | 2-5 min |
| Phase 0 — Download | 5-15 min |
| Phase 4 — Restore | 30-60 min |
| Phase 7 — Seeding | 5-45 min |
| **Total** | **45-90 min** |

---

## Part 6: Monitoring

### ADO Pipeline History
ADO > Pipelines > AG Refresh — Run Refresh > Runs — full audit trail per refresh

### Email Notifications
Configured via ADO > Project Settings > Notifications.
Fires on build complete (success and failure) to DBA team email.

### Log Analytics (if configured)
Azure Portal > your-automation-account > Diagnostic settings > JobLogs + JobStreams
See [`/kql/ag-refresh-monitoring.kql.md`](../kql/ag-refresh-monitoring.kql.md) for queries.

### Local Logs on Hybrid Workers
```
H:\WORKDIR\Logs\AGRefresh_<date>_<runid>.log
```
Use the RunId from ADO job output to cross-reference:
```powershell
Get-Content H:\WORKDIR\Logs\*.log | Where-Object { $_ -like "*<RunId>*" }
```

---

## Part 7: Adding a New Environment

When you're ready to expand beyond URT:

1. Provision the Automation Account and Hybrid Workers for the new environment
2. Assign RBAC: Reader, Automation Contributor, Monitoring Reader on the new RG
3. Create ADO variable group `ag-refresh-config-<env>` with correct `AUTOMATION_ACCOUNT_NAME`
4. Create ADO environment `AG-REFRESH-<ENV>` (add approval gate if PROD)
5. Add the new environment to `TargetEnvironment` values in `ag-refresh.yml`
6. Add `${{ if }}` blocks for the new variable group and environment
7. Register new Hybrid Worker VMs as ADO agents in the pool
8. Run deploy pipeline to push scripts to new workers
9. Test with a non-critical database first
