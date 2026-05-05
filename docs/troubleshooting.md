# Troubleshooting Guide

---

## How to Investigate a Failed Job

1. Azure Portal > aa-sql-refresh-stg > Jobs > select the failed job
2. Click **Output** tab — verbose output shows which phase failed
3. Click **Errors** tab — exception message and stack trace
4. Cross-reference with local log on the Hybrid Worker VM:
   ```
   H:\WORKDIR\Logs\AGRefresh_<date>_<RunId>.log
   ```
5. Use the RunId from the job output to grep across all log files:
   ```powershell
   Get-Content H:\WORKDIR\Logs\*.log | Where-Object { $_ -like "*<RunId>*" }
   ```

---

## Common Failures

### Phase 0: No backup files found
- **Cause:** Wrong `BackupDate`, `BackupNamePrefix`, or `ContainerName`
- **Fix:** Browse the Blob container in Azure Portal and confirm file names and `LastModified` date match exactly

### Phase 0: Destination directory not empty
- **Cause:** Stale `.bak` files from a previous run that did not clean up
- **Fix:** RDP to primary > delete `H:\WORKDIR\AutomatedRefresh\*.bak` > re-run

### Phase 0: AG not healthy
- **Cause:** Pre-existing sync issue on a replica
- **Fix:** Resolve AG health in SSMS before re-running. Do not force a refresh over an unhealthy AG.

### Phase 0: Managed Identity auth failure
- **Cause:** `Storage Blob Data Reader` role not assigned, or wrong storage account
- **Fix:** Azure Portal > yourstorageaccount > Access control (IAM) > verify role assignment to `aa-sql-refresh-stg` Managed Identity

### Phase 2: Drop fails on secondary
- **Cause:** Active connections blocking the drop, or service account lacks permissions
- **Fix:** Connect to secondary in SSMS, kill active sessions, verify service account has sysadmin

### Phase 4: Restore fails — file not found
- **Cause:** MOVE paths in `tscript.sql` don't match actual volume labels on the server
- **Fix:** Check `CreateRefreshScript.ps1` parameters (`DataDrive`, `LogDrive`, `FileStreamDrive`) match actual server paths. Verify with `Get-PSDrive` on the target.

### Phase 4: Restore fails — database in use
- **Cause:** The session kill in `tscript.sql` didn't catch all connections
- **Fix:** Manually kill remaining sessions in SSMS: `KILL <spid>` then re-run from Phase 4

### Phase 5: Post-restore SQL error
- **Cause:** Missing table, role, or object in target environment; or environment-specific CASE block doesn't match server+database name
- **Fix:** Review the specific section error in `H:\WORKDIR\Logs\PostRefresh_*.log`. Run that section of `DatabasePostRestore.sql` manually in SSMS to see the exact error.

### Phase 7: Seeding timeout
- **Cause:** Large database or slow network; seeding is running but exceeded the timeout
- **Fix:** Increase `SeedingTimeoutMinutes` parameter (try 90). Phase 8 auto-repair will attempt recovery. Check `sys.dm_hadr_automatic_seeding` directly for current state.

### Phase 7/8: Seeding FAILED — replica won't seed
- **Cause:** Replica ran out of disk space, or `CREATE ANY DATABASE` not granted
- **Fix:** Phase 8 grants `CREATE ANY DATABASE` automatically. If it still fails, check disk space on the secondary and verify AG automatic seeding mode is set.

### Worker not found / job queuing indefinitely
- **Cause:** Hybrid Worker is offline or the `demands` targeting doesn't match any worker
- **Fix:** Azure Portal > Automation Account > Hybrid Worker Groups > sql-ag-workers > Workers tab. If a server shows Offline, restart the HybridWorkerExtension service on that VM.

---

## Manual Recovery Steps by Phase

### If restore left the database OFFLINE (Phase 4 failure)
```sql
-- Bring it back online manually
ALTER DATABASE [YOUR_DATABASE] SET ONLINE;

-- Or restore from a known-good backup if the restore was partial
```

### If database was removed from AG but restore failed
```sql
-- Re-add standalone DB back to AG after fixing restore
ALTER AVAILABILITY GROUP [YOUR_AG_NAME]
ADD DATABASE [YOUR_DATABASE];
```

### If seeding is stuck on a specific secondary
```sql
-- On the secondary — check state
SELECT database_name, current_state_desc, failure_state_desc
FROM sys.dm_hadr_automatic_seeding;

-- On the primary — force re-seed
ALTER AVAILABILITY GROUP [YOUR_AG_NAME]
    MODIFY REPLICA ON N'SECONDARY_NAME'
    WITH (SEEDING_MODE = AUTOMATIC);

-- On the secondary — ensure permission
ALTER AVAILABILITY GROUP [YOUR_AG_NAME]
    GRANT CREATE ANY DATABASE;
```

---

## Quick Health Check Queries (Run on Primary in SSMS)

```sql
-- AG replica health
SELECT ag.name, rs.role_desc, rs.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states rs ON ag.group_id = rs.group_id;

-- Current seeding status
SELECT database_name, current_state_desc, failure_state_desc,
       CAST(transferred_size_bytes/1048576.0 AS DECIMAL(10,1)) AS TransferredMB
FROM sys.dm_hadr_automatic_seeding;

-- Database AG membership
SELECT ag.name, adc.database_name, db.state_desc
FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON adc.group_id = ag.group_id
JOIN sys.databases db ON adc.database_name = db.name;
```
