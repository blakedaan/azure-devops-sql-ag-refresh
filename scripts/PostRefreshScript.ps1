<#
.SYNOPSIS
    Executes the post-restore SQL script (DatabasePostRestore.sql) after a successful
    database restore.

.DESCRIPTION
    Runs DatabasePostRestore.sql against the restored database. This script handles
    all post-restore configuration tasks including permissions, environment-specific
    settings, OAuth/router configuration, and user cleanup.

    Designed to run as Phase 5 of the AG refresh orchestration pipeline on the
    primary replica Hybrid Worker. Uses Windows Authentication.

.PARAMETER DatabaseName
    The name of the restored database to run post-refresh against.
    Default: YOUR_DATABASE

.PARAMETER SqlScriptPath
    Full path to the DatabasePostRestore.sql file.
    Default: H:\WORKDIR\Scripts\DatabasePostRestore.sql

.PARAMETER LogDirectory
    Directory where log files are written.
    Default: H:\WORKDIR\Logs

.PARAMETER SqlInstance
    SQL Server instance to connect to.
    Default: . (localhost)

.NOTES
    Author       : Your Name | Co-Author
    Version      : 2.1
    Last Updated : April 2026
    Run Context  : Azure Automation Hybrid Runbook Worker
    Auth         : Windows Authentication via Hybrid Worker service account
#>

param (
    [string]$DatabaseName  = 'YOUR_DATABASE',
    [string]$SqlScriptPath = 'H:\WORKDIR\Scripts\DatabasePostRestore.sql',
    [string]$LogDirectory  = 'H:\WORKDIR\Logs',
    [string]$SqlInstance   = '.'
)

#region Initialization

$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'Continue'

$TimeStamp   = Get-Date -Format 'yyyy-MM-dd'
$RunId       = [Guid]::NewGuid().ToString().Substring(0, 8)
$LogFilePath = Join-Path $LogDirectory "PostRefresh_${TimeStamp}_${RunId}.log"

# SqlServer module v22+ defaults to Encrypt=Mandatory.
# Disabled bypasses SSL for internal SQL Servers with self-signed certificates.
$PSDefaultParameterValues['Invoke-Sqlcmd:Encrypt'] = 'Disabled'

#endregion Initialization

#region Logging

if (-not (Test-Path (Split-Path $LogFilePath))) {
    New-Item -Path (Split-Path $LogFilePath) -ItemType Directory -Force | Out-Null
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

Write-Log "PostRefreshScript starting. RunId: $RunId"
Write-Log "Database: $DatabaseName | Instance: $SqlInstance"
Write-Log "SQL script: $SqlScriptPath"

if (-not (Test-Path $SqlScriptPath)) {
    Write-Log "SQL script not found: $SqlScriptPath" 'ERROR'
    throw "SQL script not found: $SqlScriptPath. Verify the DatabasePostRestore.sql path."
}

#endregion Validate Inputs

#region Execute Post-Refresh

$startTime = Get-Date

try {
    Write-Log "Starting post-refresh SQL execution..."

    Invoke-Sqlcmd `
        -ServerInstance  $SqlInstance `
        -Database        $DatabaseName `
        -InputFile       $SqlScriptPath `
        -ConnectionTimeout 30 `
        -QueryTimeout    0 `
        -OutputSqlErrors $true `
        -TrustServerCertificate `
        -Verbose

    $duration = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
    Write-Log "Post-refresh SQL completed successfully in ${duration} minutes."
}
catch {
    $duration = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
    Write-Log "Post-refresh FAILED after ${duration} minutes." 'ERROR'
    Write-Log "Error: $($_.Exception.Message)" 'ERROR'
    Write-Log "Stack trace: $($_.Exception.StackTrace)" 'ERROR'
    throw
}
finally {
    $finTs = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Log "PostRefreshScript finished at $finTs. RunId: $RunId"
}

#endregion Execute Post-Refresh
