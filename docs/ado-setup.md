# Azure DevOps Setup Guide

Code lives in the YOUR_ORG GitHub org. ADO Pipelines reads from GitHub and executes
on Hybrid Workers. This guide covers one-time setup steps.

---

## Step 1: Identify the ADO Project

```
Organization: dev.azure.com/YOUR_ADO_ORG
Project:      YOUR_ADO_PROJECT
```

---

## Step 2: Connect ADO to the YOUR_ORG GitHub Org

YOUR_ORG already has ADO pipelines running from GitHub — this connection likely exists.

1. ADO > Project Settings > GitHub connections
2. If YOUR_ORG org is listed — use it, skip to Step 3
3. If not: New GitHub connection > GitHub App > authorize the YOUR_ORG org

---

## Step 3: Push Code to GitHub

```bash
git clone https://github.com/YOUR_ORG/your-ag-refresh-repo
cd your-ag-refresh-repo
git add .
git commit -m "Initial commit: AG refresh automation"
git push origin main
```

---

## Step 4: Configure Branch Protection in GitHub

1. GitHub > repo > Settings > Branches > Add branch protection rule
2. Branch name pattern: `main`
3. Enable: **Require a pull request before merging**
4. Enable: **Require status checks to pass** (link ag-validate.yml — do Step 8 first)
5. Enable: **Require branches to be up to date before merging**
6. Enable: **Do not allow bypassing the above settings**
7. Save

---

## Step 5: Create ADO Service Connection

> **Important:** This service connection points at the **production subscription**
> because all environments pull backups from `yourstorageaccount`.
> You need Contributor on `your-prod-subscription-name` to create this.
> Ask Alberto to create it — provide him the details below.

**Ask Alberto:**
```
Connection name:  your-service-connection
Subscription:     your-prod-subscription-name
Resource group:   rg-scus-prd-sql-backups-storage-001
Managed identity: your-automation-account
Object ID:        [paste from Azure Portal > your-automation-account > Identity]
```

Once created, verify it appears in ADO > Project Settings > Service connections.

---

## Step 6: Create Variable Groups — One Per Environment

Each environment gets its own variable group. The pipeline selects the correct
group automatically at runtime based on the `TargetEnvironment` parameter.

### ag-refresh-config-urt (create now — active environment)

1. ADO > Pipelines > Library > + Variable group
2. Name: `ag-refresh-config-urt`
3. Add variables:

| Variable | Value | Secret? |
|---|---|---|
| `AUTOMATION_ACCOUNT_NAME` | your-automation-account | No |
| `STORAGE_ACCOUNT_NAME` | yourstorageaccount | No |
| `CONTAINER_NAME` | your-container | No |
| `BACKUP_NAME_PREFIX` | YourPrefix_ | No |
| `SERVICE_CONNECTION` | your-service-connection | No |

4. Save

### ag-refresh-config-triage (create now for future use)

Same steps — Name: `ag-refresh-config-triage`

| Variable | Value |
|---|---|
| `AUTOMATION_ACCOUNT_NAME` | aa-scus-triage-sql-refresh-001 *(update when provisioned)* |
| `STORAGE_ACCOUNT_NAME` | yourstorageaccount |
| `CONTAINER_NAME` | your-container |
| `BACKUP_NAME_PREFIX` | YourPrefix_ |
| `SERVICE_CONNECTION` | your-service-connection |

### ag-refresh-config-stg and ag-refresh-config-prod (create when needed)

Same structure. Update `AUTOMATION_ACCOUNT_NAME` to the correct automation account
for that environment when you provision it.

---

## Step 7: Create ADO Environments

1. ADO > Pipelines > Environments > New environment

Create all four — Resource: None for each:

| Environment | Approval | Notes |
|---|---|---|
| `AG-REFRESH-URT` | None | Current active environment — runs immediately |
| `AG-REFRESH-TRIAGE` | None | Future — runs immediately when used |
| `AG-REFRESH-STG` | None | Future — runs immediately when used |
| `AG-REFRESH-PROD` | **Manual approval required** | Future — always gated |

**For AG-REFRESH-PROD only:**
- Approvals and checks > + Add > Approvals
- Approvers: yourself + team lead
- Timeout: 24 hours
- Instructions: `Confirm backup date, AG health, and stakeholder notification before approving`
- Save

> **WARNING:** PROD approval gate must never be removed. Every PROD refresh
> should have a named human who approved it.

---

## Step 8: Create the Three Pipelines from GitHub

### PR Validation Pipeline
1. ADO > Pipelines > New pipeline > **GitHub** (not Azure Repos Git)
2. Select the YOUR_ORG org connection > repo: `your-ag-refresh-repo`
3. Existing Azure Pipelines YAML file > `/pipelines/ag-validate.yml`
4. Save > Rename to: `AG Refresh — PR Validation`

### Deploy Pipeline
1. New pipeline > GitHub > same repo > `/pipelines/ag-deploy.yml`
2. Save > Rename to: `AG Refresh — Deploy Scripts`
3. Edit > Variables > Variable groups > Link `ag-refresh-config-urt`

### Refresh Pipeline
1. New pipeline > GitHub > same repo > `/pipelines/ag-refresh.yml`
2. Save > Rename to: `AG Refresh — Run Refresh`
3. Edit > Variables > Variable groups > Link all four variable groups:
   - `ag-refresh-config-urt`
   - `ag-refresh-config-triage`
   - `ag-refresh-config-stg`
   - `ag-refresh-config-prod`

> **Note:** Linking all variable groups to the pipeline does not mean all variables
> are active at once. The pipeline YAML uses `${{ if }}` expressions to select only
> the correct group based on `TargetEnvironment` at runtime.

---

## Step 9: Set Up Email Notifications

No Teams webhook needed. Use ADO's built-in notification system:

1. ADO > Project Settings > Notifications > + New subscription
2. Category: **Build** | Event: **Build completed**
3. Filter: Pipeline name = `AG Refresh — Run Refresh`
4. Send to: DBA team email address or distribution list
5. Save

This fires automatically on both success and failure.

---

## Step 10: Create Agent Pool and Register Hybrid Workers

### Create the pool
1. ADO > Organization Settings > Agent pools > Add pool
2. Type: **Self-hosted** | Name: `your-automation-account`
3. Auto-provision in all projects: checked
4. Create

### Register each SQL VM as an agent
Run as Administrator on each replica (primary and all secondaries):

```powershell
Invoke-WebRequest -Uri 'https://vstsagentpackage.azureedge.net/agent/3.x.x/vsts-agent-win-x64-3.x.x.zip' -OutFile 'C:\agent.zip'
Expand-Archive 'C:\agent.zip' -DestinationPath 'C:\agent'

cd C:\agent
.\config.cmd `
    --url   'https://dev.azure.com/YOUR_ADO_ORG' `
    --auth  PAT `
    --token 'YOUR_ADO_PAT' `
    --pool  'your-automation-account' `
    --agent $env:COMPUTERNAME `
    --runAsService `
    --windowsLogonAccount  'YOUR_DOMAIN\your_service_account' `
    --windowsLogonPassword 'SERVICE_ACCOUNT_PASSWORD'
```

Repeat on all replicas. Verify in ADO > Organization Settings > Agent pools > Agents tab.

---

## Step 11: Link Branch Protection in GitHub

Return to GitHub after the PR validation pipeline exists:

1. GitHub > repo > Settings > Branches > main > Edit
2. Require status checks > search for `AG Refresh — PR Validation`
3. Add as required check > Save

---

## Step 12: First Deployment Run

1. ADO > Pipelines > AG Refresh — Deploy Scripts > Run pipeline > branch: main
2. Validate stage — syntax check on hosted agent
3. Deploy stage — creates directories, copies 6 files to H:\WORKDIR\Scripts\ on each worker
4. Verify step output — confirms all files present on every worker

---

## Validation Checklist

- [ ] YOUR_ORG GitHub org connection exists in ADO
- [ ] Code pushed to GitHub org repo
- [ ] Branch protection on main configured (link status check after Step 8)
- [ ] Service connection `your-service-connection` created by Alberto
- [ ] Variable group `ag-refresh-config-urt` created with all 5 variables
- [ ] Variable group `ag-refresh-config-triage` created (placeholder values ok)
- [ ] Variable group `ag-refresh-config-stg` created (placeholder values ok)
- [ ] Variable group `ag-refresh-config-prod` created (placeholder values ok)
- [ ] `AG-REFRESH-URT` environment created (no approval)
- [ ] `AG-REFRESH-TRIAGE` environment created (no approval)
- [ ] `AG-REFRESH-STG` environment created (no approval)
- [ ] `AG-REFRESH-PROD` environment created (manual approval configured)
- [ ] All three pipelines created from GitHub source
- [ ] All four variable groups linked to refresh pipeline
- [ ] Email notification subscription created
- [ ] Agent pool `your-automation-account` created
- [ ] All Hybrid Worker VMs registered as ADO agents — Status: Online
- [ ] First deploy run completed — 6 files present on all workers
- [ ] Test refresh run — URT, YOUR_DATABASE — AG HEALTHY after seeding

---

## Adding a New Environment Later

1. Provision the Automation Account and Hybrid Workers
2. Create variable group `ag-refresh-config-<env>`
3. Create ADO environment `AG-REFRESH-<ENV>` (with approval gate if PROD)
4. Add environment to `TargetEnvironment` values in `ag-refresh.yml`
5. Add `${{ if }}` block in the variables and environment sections
6. Register new Hybrid Workers in the ADO agent pool
7. Run deploy pipeline to push scripts to new workers
