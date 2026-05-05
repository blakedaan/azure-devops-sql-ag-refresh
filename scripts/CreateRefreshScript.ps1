<#
.SYNOPSIS
    Generates a dynamic T-SQL RESTORE DATABASE script based on .bak files
    found in the backup directory.

.DESCRIPTION
    Scans a directory for .bak files, constructs a RESTORE DATABASE T-SQL script
    using the correct MOVE directives and multi-file DISK references, and writes
    the output to tscript.sql for execution by DatabaseRefresh.ps1.

    Includes structured logging, error handling, and validation of inputs.
    Designed to run on an Azure Automation Hybrid Runbook Worker as Phase 3
    of the AG refresh orchestration pipeline.

.PARAMETER BackupDirectory
    The directory containing the downloaded .bak files.
    Default: H:\WORKDIR\AutomatedRefresh

.PARAMETER LogDirectory
    The directory where log files are written.
    Default: H:\WORKDIR\Logs

.PARAMETER DatabaseName
    The name of the database to restore (target environment name).
    Default: YOUR_DATABASE

.PARAMETER DataDrive
    Full path to the data file directory on the target server.
    Default: F:\MSSQL\Data

.PARAMETER LogDrive
    Full path to the log file directory on the target server.
    Default: H:\MSSQL\Log

.PARAMETER FileStreamDrive
    Drive letter or path for the filestream/filegroup.
    Default: M:

.PARAMETER SourceLogicalDataName
    Logical name of the data file in the source backup.
    Default: YourPrefix_data

.PARAMETER SourceLogicalLogName
    Logical name of the log file in the source backup.
    Default: YourPrefix_log

.PARAMETER SourceLogicalFsName
    Logical name of the filestream in the source backup.
    Default: YourPrefix_fs

.NOTES
    Author       : Your Name | Co-Author
    Version      : 2.1
    Last Updated : April 2026
    Run Context  : Azure Automation Hybrid Runbook Worker
#>

param (
    [string]$BackupDirectory       = 'H:\WORKDIR\AutomatedRefresh',
    [string]$LogDirectory          = 'H:\WORKDIR\Logs',
    [string]$DatabaseName          = 'YOUR_DATABASE',
    [string]$DataDrive             = 'F:\MSSQL\Data',
    [string]$LogDrive              = 'H:\MSSQL\Log',
    [string]$FileStreamDrive       = 'M:',
    [string]$SourceLogicalDataName = 'YourPrefix_data',
    [string]$SourceLogicalLogName  = 'YourPrefix_log',
    [string]$SourceLogicalFsName   = 'YourPrefix_fs'
)

#region Initialization

$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'

$TimeStamp   = Get-Date -Format 'yyyy-MM-dd'
$LogFilePath = Join-Path $LogDirectory "CreateRefreshScript_${TimeStamp}.log"
$OutputPath  = Join-Path $BackupDirectory 'tscript.sql'

# Resolve target file paths
$DataFilePath    = Join-Path $DataDrive     "${DatabaseName}.mdf"
$LogFilePathDb   = Join-Path $LogDrive      "${DatabaseName}_1.ldf"
$FileStreamPath  = Join-Path $FileStreamDrive "${DatabaseName}_fg"

#endregion Initialization

#region Logging

if (-not (Test-Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param ([string]$Message, [string]$Level = 'INFO')
    $ts      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "$ts [$Level] $Message"
    Write-Output $logLine
    Add-Content -Path $LogFilePath -Value $logLine -ErrorAction SilentlyContinue
}

#endregion Logging

#region Validate Inputs

Write-Log "Starting restore script generation for database: $DatabaseName"
Write-Log "Backup directory: $BackupDirectory"
Write-Log "Output path: $OutputPath"

if (-not (Test-Path $BackupDirectory)) {
    Write-Log "Backup directory not found: $BackupDirectory" 'ERROR'
    throw "Backup directory not found: $BackupDirectory"
}

#endregion Validate Inputs

#region Locate Backup Files

try {
    $BackupFiles = Get-ChildItem -Path $BackupDirectory -Filter '*.bak' -File |
                   Sort-Object -Property Name

    if ($BackupFiles.Count -eq 0) {
        Write-Log "No .bak files found in $BackupDirectory" 'ERROR'
        throw "No backup files found in backup directory: $BackupDirectory"
    }

    Write-Log "Found $($BackupFiles.Count) backup file(s)."

    # Build DISK = N'...' list
    if ($BackupFiles.Count -eq 1) {
        $RestoreMediaList = "DISK = N'$($BackupDirectory)\$($BackupFiles[0].Name)'"
    }
    else {
        $diskLines = @()
        foreach ($file in $BackupFiles) {
            $diskLines += "`t`tDISK = N'$BackupDirectory\$($file.Name)'"
        }
        # Join with comma+newline, last entry has no trailing comma
        $RestoreMediaList = ($diskLines[0..($diskLines.Count - 2)] | ForEach-Object { "$_," }) -join "`n"
        $RestoreMediaList += "`n$($diskLines[-1])"
    }

    Write-Log "Restore media list constructed with $($BackupFiles.Count) file(s)."
}
catch {
    Write-Log "Error locating backup files: $_" 'ERROR'
    throw
}

#endregion Locate Backup Files

#region Build SQL Script

$RestoreSqlScript = @"
USE [master];
GO
BEGIN TRY
    --------------------------------------------------------------------------------
    -- KILL ALL ACTIVE SESSIONS CONNECTED TO THE DATABASE
    -- Ensures no blocking connections prevent the offline/restore operations
    --------------------------------------------------------------------------------
    DECLARE @killCommand NVARCHAR(MAX) = N'';

    SELECT @killCommand += 'KILL ' + CAST(session_id AS NVARCHAR(10)) + '; '
    FROM sys.dm_exec_sessions
    WHERE database_id = DB_ID('$DatabaseName')
      AND session_id <> @@SPID;

    IF LEN(@killCommand) > 0
    BEGIN
        RAISERROR('Killing active sessions: %s', 10, 1, @killCommand) WITH NOWAIT;
        EXEC sp_executesql @killCommand;
    END

    --------------------------------------------------------------------------------
    -- SET DATABASE OFFLINE WITH IMMEDIATE ROLLBACK
    --------------------------------------------------------------------------------
    SET DEADLOCK_PRIORITY HIGH;
    ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE;
    RAISERROR('Database set to OFFLINE.', 10, 1) WITH NOWAIT;

    --------------------------------------------------------------------------------
    -- RESTORE DATABASE
    --------------------------------------------------------------------------------
    RAISERROR('Starting RESTORE DATABASE...', 10, 1) WITH NOWAIT;

    RESTORE DATABASE [$DatabaseName]
    FROM
$RestoreMediaList
    WITH FILE = 1,
        MOVE N'$SourceLogicalDataName' TO N'$DataFilePath',
        MOVE N'$SourceLogicalLogName'  TO N'$LogFilePathDb',
        MOVE N'$SourceLogicalFsName'   TO N'$FileStreamPath',
        REPLACE,
        STATS = 10;

    --------------------------------------------------------------------------------
    -- SET DATABASE ONLINE
    --------------------------------------------------------------------------------
    ALTER DATABASE [$DatabaseName] SET ONLINE;
    RAISERROR('Database set to ONLINE. Restore complete.', 10, 1) WITH NOWAIT;

END TRY
BEGIN CATCH
    DECLARE @ErrorMessage  NVARCHAR(MAX) = ERROR_MESSAGE();
    DECLARE @ErrorSeverity INT           = ERROR_SEVERITY();
    DECLARE @ErrorState    INT           = ERROR_STATE();

    RAISERROR('Database restore failed: %s', @ErrorSeverity, @ErrorState, @ErrorMessage);
END CATCH;
GO
"@

#endregion Build SQL Script

#region Write Script to File

try {
    $RestoreSqlScript | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
    Write-Log "Restore script written to: $OutputPath"

    # Brief pause to ensure file system flush before downstream scripts read it
    Start-Sleep -Seconds 2
}
catch {
    Write-Log "Failed to write restore script to file: $_" 'ERROR'
    throw
}

#endregion Write Script to File

Write-Log "CreateRefreshScript completed successfully. Output: $OutputPath"
