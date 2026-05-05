<#
.SYNOPSIS
    Downloads SQL Server backup files from Azure Blob Storage to a local disk
    using Managed Identity, validates integrity, and enforces a clean workspace.

.DESCRIPTION
    This script is designed to run on an Azure Automation Hybrid Runbook Worker
    (hosted on a SQL Server VM). It connects to Azure using a system-assigned
    Managed Identity, locates SQL Server backup (.bak) files in Azure Blob Storage
    based on a specified backup date and naming prefix, downloads them to a local
    directory, validates file integrity (non-zero size), and optionally cleans
    up the downloaded files after execution.

    The script is safe for:
    - Availability Group (AG) refresh workflows
    - Non-AG database refresh workflows
    - Cross-subscription backup access (via RBAC)
    - Non-interactive, automated execution

.NOTES
    Author       : Your Name | Co-Author
    Version      : 2.1
    Last Updated : April 2026
    PowerShell   : Compatible with PowerShell 7.x
    Run Context  : Azure Automation Hybrid Runbook Worker (SQL Server VM)
    Authentication: System-assigned Managed Identity

    Requirements:
    - Az.Accounts module installed on the Hybrid Worker VM
    - Az.Storage module installed on the Hybrid Worker VM
    - Outbound network access from the VM to Azure Blob Storage

    Permissions:
    - Automation Account Managed Identity must have:
        Storage Blob Data Reader on the source storage account
    - Hybrid Worker service account must have:
        Read/Write access to the destination and log directories

.DESIGN NOTES
    - This script intentionally does NOT install or update PowerShell modules at runtime.
    - Backup files are downloaded locally because SQL Server on VMs cannot restore
      directly from Azure Blob Storage.
    - The script enforces an empty destination directory before downloading to prevent
      accidental restores from stale files.
    - Intended to be executed on the PRIMARY replica only during AG refresh operations.
    - Uses UseConnectedAccount (Managed Identity) instead of storage account keys.
      No keys, no secrets, no plaintext credentials anywhere.
#>

param (
    [Parameter(Mandatory)]
    [datetime]$BackupDate,

    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [string]$ContainerName,

    [Parameter(Mandatory)]
    [string]$BackupNamePrefix,

    [Parameter()]
    [string]$DestinationPath = 'H:\WORKDIR\AutomatedRefresh',

    [Parameter()]
    [string]$LogDirectory = 'H:\WORKDIR\Logs',

    [switch]$CleanupAfterRun
)

#region Initialization

$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'Continue'

$RunId     = [Guid]::NewGuid()
$DateStamp = Get-Date -Format 'yyyy-MM-dd'
$LogFile   = Join-Path $LogDirectory "DownloadBackups_${DateStamp}_${RunId}.log"

#endregion Initialization

#region Logging

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine   = "$timestamp [$Level] $Message"
    Write-Output $logLine
    Add-Content -Path $LogFile -Value $logLine -ErrorAction SilentlyContinue
}

#endregion Logging

try {
    #region Setup & Validation

    if (-not (Test-Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    Write-Log "RunId: $RunId"
    Write-Log "Starting backup download for date: $($BackupDate.ToString('yyyy-MM-dd'))"
    Write-Log "Storage Account: $StorageAccountName | Container: $ContainerName | Prefix: $BackupNamePrefix"

    if (-not (Test-Path $DestinationPath)) {
        Write-Log "Creating destination directory: $DestinationPath"
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
    }

    # Enforce clean destination directory — prevents accidental restore from stale files
    $existingFiles = Get-ChildItem -Path $DestinationPath -File -ErrorAction SilentlyContinue
    if ($existingFiles) {
        throw "Destination directory '$DestinationPath' is not empty ($($existingFiles.Count) file(s) found). " +
              "Remove stale files before running. Aborting to prevent accidental restore."
    }

    #endregion Setup & Validation

    #region Azure Authentication

    Write-Log "Connecting to Azure using user-assigned Managed Identity..."
    # Using user-assigned MI (your-user-assigned-mi) explicitly
    # to avoid connecting as the VM's own system-assigned MI which lacks blob access.
    Connect-AzAccount -Identity -AccountId 'YOUR_USER_ASSIGNED_MI_CLIENT_ID' | Out-Null

    # Set context to prod subscription where yourstorageaccount lives
    Set-AzContext -SubscriptionId 'YOUR_PROD_SUBSCRIPTION_ID' | Out-Null
    Write-Log "Azure context set to your-prod-subscription-name."

    # UseConnectedAccount = Managed Identity — no storage key needed, no secrets
    $StorageContext = New-AzStorageContext `
        -StorageAccountName $StorageAccountName `
        -UseConnectedAccount

    Write-Log "Connected to Azure. Storage context established."

    #endregion Azure Authentication

    #region Locate Backup Files

    Write-Log "Listing blobs in container '$ContainerName' with prefix '$BackupNamePrefix'..."
    $Blobs = Get-AzStorageBlob -Context $StorageContext -Container $ContainerName

    $TargetBlobs = $Blobs | Where-Object {
        $_.Name -like "$BackupNamePrefix*.bak" -and
        $_.LastModified.UtcDateTime.Date -eq $BackupDate.Date
    } | Sort-Object -Property Name

    if (-not $TargetBlobs) {
        throw "No backup files found for $($BackupDate.ToString('yyyy-MM-dd')) using prefix '$BackupNamePrefix'. " +
              "Verify the backup date, prefix, container name, and storage account."
    }

    Write-Log "Found $($TargetBlobs.Count) backup file(s) to download."

    #endregion Locate Backup Files

    #region Download & Validate Backups

    $Index           = 0
    $TotalSizeBytes  = 0

    foreach ($Blob in $TargetBlobs) {
        $Index++
        $DestinationFile = Join-Path $DestinationPath $Blob.Name

        Write-Progress `
            -Activity  "Downloading SQL Server backup files" `
            -Status    "File $Index of $($TargetBlobs.Count): $($Blob.Name)" `
            -PercentComplete (($Index / $TargetBlobs.Count) * 100)

        Write-Log "Downloading [$Index/$($TargetBlobs.Count)]: '$($Blob.Name)'"

        Get-AzStorageBlobContent `
            -Context    $StorageContext `
            -Container  $ContainerName `
            -Blob       $Blob.Name `
            -Destination $DestinationFile `
            -Force | Out-Null

        $DownloadedFile = Get-Item $DestinationFile -ErrorAction Stop

        if ($DownloadedFile.Length -eq 0) {
            throw "Downloaded file '$DestinationFile' is 0 bytes. Aborting — file is corrupt or incomplete."
        }

        $TotalSizeBytes += $DownloadedFile.Length
        $SizeMB = [math]::Round($DownloadedFile.Length / 1MB, 1)
        Write-Log "Validated: '$($Blob.Name)' — ${SizeMB} MB"
    }

    $TotalSizeMB = [math]::Round($TotalSizeBytes / 1MB, 1)
    Write-Log "All $($TargetBlobs.Count) backup file(s) downloaded and validated. Total size: ${TotalSizeMB} MB."

    #endregion Download & Validate Backups
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.Exception.StackTrace 'ERROR'
    throw
}
finally {
    if ($CleanupAfterRun) {
        Write-Log "CleanupAfterRun enabled — removing downloaded backup files from '$DestinationPath'"
        Remove-Item "$DestinationPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Disconnecting from Azure..."
    Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
    Write-Log "Backup download process completed. RunId: $RunId"
}
