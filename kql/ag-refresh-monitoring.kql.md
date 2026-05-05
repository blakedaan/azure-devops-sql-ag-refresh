# KQL — AG Database Refresh Monitoring

Queries for monitoring AG refresh jobs via Azure Automation job logs
and any custom Log Analytics tables if you extend the runbook with
Write-DeploymentEvent-style logging in the future.

---

## Azure Automation Job Monitoring

These queries run against the `AzureActivity` and `AzureDiagnostics`
tables populated when Azure Automation is connected to a Log Analytics Workspace.

### Connect Automation Account to Log Analytics
1. Azure Portal > aa-sql-refresh-stg > Diagnostic settings
2. Add diagnostic setting
3. Select: JobLogs, JobStreams
4. Destination: your Log Analytics Workspace
5. Save — logs begin flowing on the next job run

---

## All AG Refresh Jobs (Last 30 Days)

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category in ("JobLogs", "JobStreams")
| where RunbookName_s == "Invoke-AGDatabaseRefresh"
| where TimeGenerated > ago(30d)
| project TimeGenerated, RunbookName_s, JobId_g, ResultType, StreamType_s, ResultDescription_s
| order by TimeGenerated desc
```

---

## Failed Refresh Jobs

**Alert name:** `Alert-AGRefresh-Failed`
**Severity:** 1 (Critical)
**Evaluate:** Every 5 min | Lookback: 15 min | Threshold: > 0 results

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| where RunbookName_s == "Invoke-AGDatabaseRefresh"
| where ResultType == "Failed"
| where TimeGenerated > ago(15m)
| project TimeGenerated, JobId_g, ResultDescription_s
```

---

## Job Output — Full Log for a Specific Job

Replace `YOUR_JOB_ID` with the GUID from the Azure Portal job details.

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where JobId_g == "YOUR_JOB_ID"
| project TimeGenerated, StreamType_s, ResultDescription_s
| order by TimeGenerated asc
```

---

## Job Duration Trend

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| where RunbookName_s == "Invoke-AGDatabaseRefresh"
| where ResultType in ("Completed", "Failed")
| where TimeGenerated > ago(90d)
| extend DurationMin = datetime_diff('minute', EndTime_t, StartTime_t)
| project TimeGenerated, ResultType, DurationMin, JobId_g
| order by TimeGenerated desc
```

---

## Phase-Level Tracing (via Verbose Output)

The orchestration runbook writes phase markers in verbose output.
Search for a specific RunId across all job streams:

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where ResultDescription_s contains "RunId:YOUR_RUN_ID"
| project TimeGenerated, StreamType_s, ResultDescription_s
| order by TimeGenerated asc
```

---

## Seeding Timeout Alerts

The runbook logs a WARNING-level message when seeding times out.
Use this to catch seeding issues before Phase 8 auto-repair kicks in:

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where RunbookName_s == "Invoke-AGDatabaseRefresh"
| where ResultDescription_s contains "did not complete within"
    or ResultDescription_s contains "FAILED"
| where TimeGenerated > ago(24h)
| project TimeGenerated, JobId_g, ResultDescription_s
```

---

## AG Health Baseline (Run Ad-Hoc from SSMS or Azure Data Studio)

Run these directly against the primary replica to check AG state
before or after a refresh:

```sql
-- Overall AG health
SELECT
    ag.name AS AGName,
    rs.role_desc,
    rs.synchronization_state_desc,
    rs.synchronization_health_desc,
    rs.operational_state_desc
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states rs
    ON ag.group_id = rs.group_id;

-- Seeding status
SELECT
    database_name,
    current_state_desc,
    failure_state_desc,
    CAST(transferred_size_bytes / 1048576.0 AS DECIMAL(10,1)) AS TransferredMB,
    CAST(database_size_bytes    / 1048576.0 AS DECIMAL(10,1)) AS TotalMB
FROM sys.dm_hadr_automatic_seeding;

-- AG database membership
SELECT
    ag.name AS AGName,
    adc.database_name,
    db.state_desc
FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON adc.group_id = ag.group_id
JOIN sys.databases db ON adc.database_name = db.name;
```
