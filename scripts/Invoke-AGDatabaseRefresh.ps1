<#
.SYNOPSIS
    Orchestrates an end-to-end SQL Server Availability Group database refresh.

.DESCRIPTION
    Phase 0 - Pre-flight checks and backup download
    Phase 1 - Remove database from Availability Group
    Phase 2 - Drop database on all secondary replicas (parallel)
    Phase 3 - Generate restore T-SQL script from downloaded .bak files
    Phase 4 - Restore database on primary replica
    Phase 5 - Run post-restore SQL configuration tasks
    Phase 6 - Add database back to Availability Group
    Phase 7 - Monitor automatic seeding
    Phase 8 - Auto-repair failed replicas (conditional)
    Phase 9 - Cleanup downloaded backup files

    StartAtPhase controls execution scope:
      Full          - Phase 0 through 9 (default)
      Download      - Phase 0 only -- pre-stage backup files, stop before destructive work
      PostDownload  - Phase 1 through 9 -- assumes files already present in DestinationPath

.NOTES
    Author       : Your Name | Co-Author
    Version      : 2.3
    Last Updated : May 2026
#>

param (
    [Parameter(Mandatory)]
    [string]$AvailabilityGroupName,

    [Parameter(Mandatory)]
    [string]$DatabaseName,

    [Parameter(Mandatory)]
    [datetime]$BackupDate,

    [Parameter(Mandatory)]
    [string]$PrimaryReplica,

    [Parameter(Mandatory)]
    [string[]]$SecondaryReplicas,

    [ValidateSet('Full', 'Download', 'PostDownload', 'Cleanup')]
    [string]$StartAtPhase          = 'Full',

    [string]$StorageAccountName    = 'yourstorageaccount',
    [string]$ContainerName         = 'your-container',
    [string]$BackupNamePrefix      = 'YourPrefix_',
    [string]$DestinationPath       = 'H:\WORKDIR\AutomatedRefresh',
    [string]$ScriptsPath           = 'H:\WORKDIR\Scripts',
    [int]$SeedingTimeoutMinutes    = 125
)

#region Initialization

$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'Continue'

$RunId     = [Guid]::NewGuid()
$StartTime = Get-Date
$LogDir    = 'H:\WORKDIR\Logs'
$DateStamp = Get-Date -Format 'yyyy-MM-dd'
$LogFile   = Join-Path $LogDir "AGRefresh_${DateStamp}_${RunId}.log"

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param ([string]$Message, [string]$Level = 'INFO')
    $ts      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "$ts [$Level] [RunId:$RunId] $Message"
    Write-Verbose $logLine
    Add-Content -Path $LogFile -Value $logLine -ErrorAction SilentlyContinue
}

Write-Log "=========================================="
Write-Log "AG Refresh Starting"
Write-Log "AG: $AvailabilityGroupName | DB: $DatabaseName"
Write-Log "Primary: $PrimaryReplica | Secondaries: $($SecondaryReplicas -join ', ')"
Write-Log "Backup Date: $($BackupDate.ToString('yyyy-MM-dd'))"
Write-Log "StartAtPhase: $StartAtPhase"
Write-Log "=========================================="

# SqlServer module v22+ defaults to Encrypt=Mandatory.
# Disabled bypasses SSL for internal SQL Servers with self-signed certificates.
$PSDefaultParameterValues['Invoke-Sqlcmd:Encrypt'] = 'Disabled'

#endregion Initialization

# ==============================================================================
# PHASE 0: Pre-Flight Checks + Backup Download
# Skipped when StartAtPhase = PostDownload
# ==============================================================================

if ($StartAtPhase -in @('Full', 'Download')) {

    Write-Log "PHASE 0: Pre-flight checks and backup download"

    try {
        Write-Log "Validating Availability Group health..."
        $agHealth = Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $PrimaryReplica -Query @"
            SELECT ag.name AS AGName, rs.synchronization_health_desc
            FROM sys.availability_groups ag
            JOIN sys.dm_hadr_availability_replica_states rs ON ag.group_id = rs.group_id
            WHERE ag.name = '$AvailabilityGroupName'
              AND rs.synchronization_health_desc <> 'HEALTHY';
"@
        if ($agHealth) {
            throw "Availability Group '$AvailabilityGroupName' has unhealthy replicas."
        }
        Write-Log "AG health check passed -- all replicas HEALTHY."

        Write-Log "Validating database '$DatabaseName' is a member of AG '$AvailabilityGroupName'..."
        $dbInAG = Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $PrimaryReplica -Query @"
            SELECT db.name
            FROM sys.availability_databases_cluster adc
            JOIN sys.availability_groups ag ON adc.group_id = ag.group_id
            JOIN sys.databases db ON adc.database_name = db.name
            WHERE ag.name = '$AvailabilityGroupName' AND db.name = '$DatabaseName';
"@
        if (-not $dbInAG) {
            throw "Database '$DatabaseName' is not a member of AG '$AvailabilityGroupName'."
        }
        Write-Log "Database membership confirmed."

        # SQL Server 2019 correct column names for sys.dm_hadr_automatic_seeding
        Write-Log "Checking for active seeding or restore operations..."
        $activeSeed = Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $PrimaryReplica -Query @"
            SELECT s.ag_db_id, s.current_state, s.start_time
            FROM sys.dm_hadr_automatic_seeding s
            JOIN sys.availability_databases_cluster adb ON s.ag_db_id = adb.group_database_id
            WHERE adb.database_name = '$DatabaseName'
              AND s.current_state NOT IN ('COMPLETED', 'FAILED')
              AND s.completion_time IS NULL;
"@
        if ($activeSeed) {
            throw "Active seeding operation detected for '$DatabaseName'. Wait for it to complete."
        }
        Write-Log "No active seeding detected."

        Write-Log "Downloading backup files from Azure Blob Storage..."
        & "$ScriptsPath\Download-SqlBackups.ps1" `
            -BackupDate         $BackupDate `
            -StorageAccountName $StorageAccountName `
            -ContainerName      $ContainerName `
            -BackupNamePrefix   $BackupNamePrefix `
            -DestinationPath    $DestinationPath

        Write-Log "PHASE 0 complete -- backup files ready in $DestinationPath"
    }
    catch {
        Write-Log "PHASE 0 FAILED: $($_.Exception.Message)" 'ERROR'
        throw
    }

    if ($StartAtPhase -eq 'Download') {
        $duration = [math]::Round(((Get-Date) - $StartTime).TotalMinutes, 1)
        Write-Log "=========================================="
        Write-Log "DOWNLOAD COMPLETE -- Stopping (StartAtPhase=Download)"
        Write-Log "Backup files staged in: $DestinationPath"
        Write-Log "Re-run with StartAtPhase=PostDownload when ready to proceed."
        Write-Log "Duration: ${duration} minutes | RunId: $RunId"
        Write-Log "=========================================="
        exit 0
    }
}
else {
    Write-Log "PHASE 0: Skipped (StartAtPhase=PostDownload) -- verifying files present..."
    $existingFiles = Get-ChildItem -Path $DestinationPath -Filter '*.bak' -ErrorAction SilentlyContinue
    if (-not $existingFiles -or $existingFiles.Count -eq 0) {
        throw "StartAtPhase=PostDownload specified but no .bak files found in '$DestinationPath'. Run Download first."
    }
    Write-Log "Found $($existingFiles.Count) .bak file(s) -- proceeding."
}

# If Cleanup only -- skip all phases, jump straight to Phase 9
if ($StartAtPhase -eq 'Cleanup') {
    Write-Log "StartAtPhase=Cleanup -- skipping all refresh phases, running cleanup only."
    $duration = $null
}
else {

# ==============================================================================
# PHASE 1: Remove Database from Availability Group
# ==============================================================================

Write-Log "PHASE 1: Removing '$DatabaseName' from AG '$AvailabilityGroupName'"

try {
    $dbInAGCheck = Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $PrimaryReplica -Query @"
        SELECT db.name
        FROM sys.availability_databases_cluster adc
        JOIN sys.availability_groups ag ON adc.group_id = ag.group_id
        JOIN sys.databases db ON adc.database_name = db.name
        WHERE ag.name = '$AvailabilityGroupName' AND db.name = '$DatabaseName';
"@

    if ($dbInAGCheck) {
        Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $PrimaryReplica -Query @"
            ALTER AVAILABILITY GROUP [$AvailabilityGroupName] REMOVE DATABASE [$DatabaseName];
"@
        Write-Log "PHASE 1 complete -- database removed from AG."
    }
    else {
        Write-Log "PHASE 1: '$DatabaseName' is already not a member of AG '$AvailabilityGroupName' -- skipping."
    }
}
catch {
    Write-Log "PHASE 1 FAILED: $($_.Exception.Message)" 'ERROR'
    throw
}

# ==============================================================================
# PHASE 2: Drop Database on All Secondary Replicas (Parallel)
# ==============================================================================

Write-Log "PHASE 2: Dropping database on $($SecondaryReplicas.Count) secondary replica(s)..."

$dropJobs = @()
foreach ($Secondary in $SecondaryReplicas) {
    Write-Log "Dispatching drop job to secondary: $Secondary"
    $dropJobs += Start-Job -ScriptBlock {
        param ($ServerName, $DbName)
        try {
            Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $ServerName -Query @"
                IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$DbName')
                BEGIN
                    -- Only set SINGLE_USER if database is online/accessible
                    -- RESTORING databases cannot be altered but can be dropped directly
                    IF (SELECT state_desc FROM sys.databases WHERE name = N'$DbName') NOT IN ('RESTORING', 'RECOVERING')
                    BEGIN
                        ALTER DATABASE [$DbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                    END

                    EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = N'$DbName';
                    DROP DATABASE [$DbName];
                END
"@
            Write-Output "SUCCESS: Dropped $DbName on $ServerName"
        }
        catch {
            Write-Output "ERROR on $ServerName : $_"
            throw
        }
    } -ArgumentList $Secondary, $DatabaseName
}

$dropResults = $dropJobs | Wait-Job | Receive-Job
$dropJobs | Remove-Job

$dropErrors = $dropResults | Where-Object { $_ -like 'ERROR*' }
if ($dropErrors) {
    Write-Log "One or more secondary drops failed:" 'ERROR'
    $dropErrors | ForEach-Object { Write-Log $_ 'ERROR' }
    throw "Phase 2 failed -- secondary replica drop errors. See log."
}

$dropResults | ForEach-Object { Write-Log $_ }
Write-Log "PHASE 2 complete -- database dropped on all secondaries."

# ==============================================================================
# PHASE 3: Generate Restore Script
# ==============================================================================

Write-Log "PHASE 3: Generating T-SQL restore script..."

try {
    & "$ScriptsPath\CreateRefreshScript.ps1" `
        -DatabaseName    $DatabaseName `
        -BackupDirectory $DestinationPath

    $scriptPath = Join-Path $DestinationPath 'tscript.sql'
    if (-not (Test-Path $scriptPath)) {
        throw "Restore script not created at: $scriptPath"
    }
    Write-Log "PHASE 3 complete -- restore script at: $scriptPath"
}
catch {
    Write-Log "PHASE 3 FAILED: $($_.Exception.Message)" 'ERROR'
    throw
}

# ==============================================================================
# PHASE 4: Restore Database on Primary Replica
# ==============================================================================

Write-Log "PHASE 4: Restoring database on primary replica: $PrimaryReplica"

try {
    & "$ScriptsPath\DatabaseRefresh.ps1" `
        -RestoreSqlScript (Join-Path $DestinationPath 'tscript.sql') `
        -SqlInstance      $PrimaryReplica

    Write-Log "PHASE 4 complete -- database restored on primary."
}
catch {
    Write-Log "PHASE 4 FAILED: $($_.Exception.Message)" 'ERROR'
    throw
}

# ==============================================================================
# PHASE 5: Post-Restore SQL Tasks
# ==============================================================================

Write-Log "PHASE 5: Running post-restore SQL configuration tasks..."

try {
    & "$ScriptsPath\PostRefreshScript.ps1" `
        -DatabaseName  $DatabaseName `
        -SqlInstance   $PrimaryReplica `
        -SqlScriptPath (Join-Path $ScriptsPath 'DatabasePostRestore.sql')

    Write-Log "PHASE 5 complete -- post-restore tasks executed."
}
catch {
    Write-Log "PHASE 5 FAILED: $($_.Exception.Message)" 'ERROR'
    throw
}

# ==============================================================================
# PHASE 6: Add Database Back to Availability Group
# ==============================================================================

Write-Log "PHASE 6: Adding '$DatabaseName' back to AG '$AvailabilityGroupName'..."

try {
    Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $PrimaryReplica -Query @"
        ALTER AVAILABILITY GROUP [$AvailabilityGroupName] ADD DATABASE [$DatabaseName];
"@
    Write-Log "PHASE 6 complete -- database added to AG. Automatic seeding initiated."
}
catch {
    Write-Log "PHASE 6 FAILED: $($_.Exception.Message)" 'ERROR'
    throw
}

# ==============================================================================
# PHASE 7: Monitor Automatic Seeding
# SQL Server 2019 correct column names: current_state (not current_state_desc)
# ==============================================================================

Write-Log "PHASE 7: Monitoring automatic seeding (timeout: $SeedingTimeoutMinutes minutes)..."

try {
    $timeout   = (Get-Date).AddMinutes($SeedingTimeoutMinutes)
    $stateDesc = 'PENDING'
    $pollCount = 0

    do {
        Start-Sleep -Seconds 30
        $pollCount++

        $seedStatus = Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $PrimaryReplica -Query @"
            SELECT TOP 1 s.current_state, s.failure_state_desc
            FROM sys.dm_hadr_automatic_seeding s
            JOIN sys.availability_databases_cluster adb ON s.ag_db_id = adb.group_database_id
            WHERE adb.database_name = '$DatabaseName'
            ORDER BY s.start_time DESC;
"@

        $stateDesc = if ($seedStatus) { $seedStatus.current_state } else { 'PENDING' }
        Write-Log "Poll $pollCount -- State: $stateDesc"

    } until ($stateDesc -in @('COMPLETED', 'FAILED') -or (Get-Date) -gt $timeout)

    if ($stateDesc -eq 'COMPLETED') {
        Write-Log "PHASE 7 complete -- automatic seeding COMPLETED."
    }
    elseif ($stateDesc -eq 'FAILED') {
        $failureReason = if ($seedStatus) { $seedStatus.failure_state_desc } else { 'Unknown' }
        Write-Log "Seeding FAILED. Reason: $failureReason" 'WARN'
    }
    else {
        throw "Seeding did not complete within $SeedingTimeoutMinutes minutes. Last state: $stateDesc."
    }
}
catch {
    Write-Log "PHASE 7 FAILED: $($_.Exception.Message)" 'ERROR'
    throw
}

# ==============================================================================
# PHASE 8: Auto-Repair Failed Replicas (Conditional)
# ==============================================================================

if ($stateDesc -eq 'FAILED') {
    Write-Log "PHASE 8: Attempting auto-repair on failed replicas..."
    try {
        foreach ($Secondary in $SecondaryReplicas) {
            $replicaState = Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $Secondary -Query @"
                SELECT rs.synchronization_health_desc
                FROM sys.availability_groups ag
                JOIN sys.dm_hadr_availability_replica_states rs ON ag.group_id = rs.group_id
                WHERE ag.name = '$AvailabilityGroupName' AND rs.is_local = 1;
"@
            if ($replicaState.synchronization_health_desc -ne 'HEALTHY') {
                Write-Log "Replica $Secondary is NOT HEALTHY. Initiating repair..."
                Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $Secondary -Query @"
                    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$DatabaseName')
                    BEGIN
                        EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = N'$DatabaseName';
                        DROP DATABASE [$DatabaseName];
                    END
"@
                Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $PrimaryReplica -Query @"
                    ALTER AVAILABILITY GROUP [$AvailabilityGroupName]
                    MODIFY REPLICA ON N'$Secondary' WITH (SEEDING_MODE = AUTOMATIC);
"@
                Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $Secondary -Query @"
                    ALTER AVAILABILITY GROUP [$AvailabilityGroupName] GRANT CREATE ANY DATABASE;
"@
                Write-Log "Repair sequence complete for $Secondary."
            }
            else {
                Write-Log "Replica $Secondary is HEALTHY -- no repair needed."
            }
        }

        Start-Sleep -Seconds 60
        $repairStatus = Invoke-Sqlcmd -TrustServerCertificate -ServerInstance $PrimaryReplica -Query @"
            SELECT TOP 1 s.current_state
            FROM sys.dm_hadr_automatic_seeding s
            JOIN sys.availability_databases_cluster adb ON s.ag_db_id = adb.group_database_id
            WHERE adb.database_name = '$DatabaseName'
            ORDER BY s.start_time DESC;
"@
        Write-Log "PHASE 8 complete. Post-repair state: $($repairStatus.current_state)"
        if ($repairStatus.current_state -ne 'COMPLETED') {
            Write-Log "WARNING: Seeding still not COMPLETED after repair. Manual verification required." 'WARN'
        }
    }
    catch {
        Write-Log "PHASE 8 FAILED: $($_.Exception.Message)" 'ERROR'
        throw
    }
}
else {
    Write-Log "PHASE 8: Skipped -- seeding completed without errors."
}

} # end if ($StartAtPhase -ne 'Cleanup')

# ==============================================================================
# PHASE 9: Cleanup
# ==============================================================================

Write-Log "PHASE 9: Cleaning up downloaded backup files from '$DestinationPath'..."

try {
    Remove-Item "$DestinationPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "PHASE 9 complete -- backup files removed."
}
catch {
    Write-Log "PHASE 9 WARNING: Cleanup error: $_. Files may need manual removal." 'WARN'
}

# ==============================================================================
# SUMMARY
# ==============================================================================

$duration = [math]::Round(((Get-Date) - $StartTime).TotalMinutes, 1)
Write-Log "=========================================="
Write-Log "AG REFRESH COMPLETED SUCCESSFULLY"
Write-Log "AG: $AvailabilityGroupName | DB: $DatabaseName"
Write-Log "StartAtPhase: $StartAtPhase"
Write-Log "Total Duration: ${duration} minutes"
Write-Log "RunId: $RunId"
Write-Log "=========================================="
