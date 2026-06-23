# ============================================================
# Stale Restore-Point Report — HPE Morpheus
# Detects:
#   HPE Morpheus backups by TypeToString
# Report-only with interactive selection and CSV export.
# ============================================================

# ---- Settings ----

if ($global:WrapperCutoffDate) {
    [datetime]$CutoffDate = $global:WrapperCutoffDate
} else {
    [datetime]$CutoffDate = '2026-06-20'
}

$LogPath = 'C:\Temp\Morpheus_Report_Log.txt'

# ---- Load Veeam PowerShell ----
try {
    Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
} catch {
    throw "Could not load the Veeam.Backup.PowerShell module: $_"
}

if (-not (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue)) {
    throw "Veeam PowerShell is not available in this session."
}

# ---- Connect ----
if (-not $global:WrapperConnected) {

    $VbrType = ''
    while ($VbrType -notin @('1','2')) {
        Write-Host ""
        Write-Host "Target type:" -ForegroundColor Cyan
        Write-Host "  [1] VSA / v13 appliance   (port 443)"
        Write-Host "  [2] Windows VBR server    (port 9392)"
        $VbrType = (Read-Host "Select 1 or 2").Trim()
    }
    $VbrPort = if ($VbrType -eq '1') { 443 } else { 9392 }

    $VbrServer = (Read-Host "Enter the VBR/VSA FQDN or IP").Trim()
    if (-not $VbrServer) { throw "No VBR/VSA address entered." }

    $cred = Get-Credential -Message "Credentials for VBR/VSA '$VbrServer'"
    if (-not $cred) { throw "No credentials supplied for '$VbrServer'." }

    try {
        Connect-VBRServer -Server $VbrServer -Port $VbrPort -Credential $cred -ErrorAction Stop
    } catch {
        throw "Failed to connect to VBR/VSA '$VbrServer': $_"
    }

    Write-Host "Connected to VBR/VSA : $VbrServer (port $VbrPort)" -ForegroundColor Cyan
}

Write-Host "Cut-off date         : $($CutoffDate.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# Logging helper
# ------------------------------------------------------------

function Write-ReportLog {
    param([string]$Message)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogPath -Value "[$timestamp] $Message"
}

if (Test-Path $LogPath) { Remove-Item $LogPath -Force }
Write-ReportLog "===== HPE Morpheus Report Started ====="
Write-ReportLog "CutoffDate: $CutoffDate"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

function Get-RawPlatform {
    param($Backup)
    try { return $Backup.BackupPlatform.Platform.ToString() } catch { return '<unknown>' }
}

function Get-RawType {
    param($Backup)
    try { return $Backup.TypeToString } catch { return '' }
}

function Resolve-RepoInfo {
    param($Repo)
    if (-not $Repo) { return [pscustomobject]@{ Name = '<unknown>'; Type = '<unknown>' } }
    $name = $Repo.Name
    $type = '<unknown>'
    try { $type = $Repo.Type.ToString() } catch { }
    try {
        if ($Repo.PSObject.Properties['IsImmutabilityEnabled'] -and $Repo.IsImmutabilityEnabled) {
            $type = "$type (Hardened/Immutable)"
        }
    } catch { }
    if ($type -match 'ScaleOut|SOBR') { $type = 'Scale-Out Backup Repository' }
    return [pscustomobject]@{ Name = $name; Type = $type }
}

function Get-MorpheusRestorePoints {
    param($Backup)

    $allPoints = @()

    try {
        $rp = Get-VBRRestorePoint -Backup $Backup -ErrorAction Stop
        if ($rp) { $allPoints += $rp }
    } catch { }

    try {
        $children = $Backup.FindChildBackups()
        if ($children) {
            foreach ($child in $children) {
                try {
                    $childRp = Get-VBRRestorePoint -Backup $child -ErrorAction Stop
                    if ($childRp) { $allPoints += $childRp }
                } catch { }
            }
        }
    } catch { }

    try {
        $oibs = [Veeam.Backup.Core.COib]::GetAll() |
                Where-Object { $_.BackupId -eq $Backup.Id }
        if ($oibs) { $allPoints += $oibs }
    } catch { }

    if ($allPoints.Count -gt 0) {
        $unique = $allPoints | Sort-Object -Property `
            @{Expression={ try { "$($_.Id)" } catch { '' } }} -Unique
        return @($unique)
    }

    return $null
}

function Test-IsFullRestorePoint {
    param($Rp)

    try {
        if ($Rp.PSObject.Properties['Type'] -and $Rp.Type) {
            if ("$($Rp.Type)" -match 'Full') { return $true }
        }
    } catch { }

    try {
        if ($Rp.PSObject.Properties['IsFull'] -and $Rp.IsFull) { return $true }
    } catch { }

    return $false
}

function Get-RestorePointChains {
    param($Points)

    $sorted = @($Points | Sort-Object CreationTime)

    $chains = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($rp in $sorted) {
        $isFull = Test-IsFullRestorePoint -Rp $rp

        if ($isFull) {
            if ($current) { $chains.Add($current) | Out-Null }

            $current = [pscustomobject]@{
                FullPoint     = $rp
                Points        = New-Object System.Collections.Generic.List[object]
                ChainStart    = $rp.CreationTime
                ChainEnd      = $rp.CreationTime
                IsLatestChain = $false
            }
            $current.Points.Add($rp) | Out-Null

        } else {
            if ($current) {
                $current.Points.Add($rp) | Out-Null
                $current.ChainEnd = $rp.CreationTime
            }
        }
    }

    if ($current) { $chains.Add($current) | Out-Null }

    $chainsArray = $chains.ToArray()

    if ($chainsArray.Count -gt 0) {
        $chainsArray[$chainsArray.Count - 1].IsLatestChain = $true
    }

    return $chainsArray
}

# ------------------------------------------------------------
# Collect HPE Morpheus chains
# ------------------------------------------------------------

$results             = New-Object System.Collections.Generic.List[object]
$encryptedBackups    = New-Object System.Collections.Generic.List[object]
$inaccessibleBackups = New-Object System.Collections.Generic.List[object]

$morpheusBackups = @(Get-VBRBackup | Where-Object {
    $typeStr = Get-RawType -Backup $_
    $typeStr -match 'HPE Morpheus'
})

Write-ReportLog "HPE Morpheus backups detected: $($morpheusBackups.Count)"

if ($morpheusBackups.Count -gt 0) {

    foreach ($backup in $morpheusBackups) {

        $rawPlatform = Get-RawPlatform -Backup $backup
        $rawType     = Get-RawType -Backup $backup

        $repoInfo = $null
        try { $repoInfo = Resolve-RepoInfo -Repo $backup.GetRepository() }
        catch { $repoInfo = [pscustomobject]@{ Name='<error>'; Type='<error>' } }

        $allPoints = Get-MorpheusRestorePoints -Backup $backup

        if (-not $allPoints) {
            try {
                Get-VBRRestorePoint -Backup $backup -ErrorAction Stop | Out-Null
            } catch {
                if ($_.Exception.Message -match 'encrypted') {
                    $encryptedBackups.Add([pscustomobject]@{
                        BackupName = $backup.Name
                        JobName    = $backup.JobName
                    }) | Out-Null
                } else {
                    $inaccessibleBackups.Add([pscustomobject]@{
                        BackupName = $backup.Name
                        JobName    = $backup.JobName
                        Reason     = $_.Exception.Message
                    }) | Out-Null
                }
            }
            continue
        }

        Write-ReportLog "Backup: $($backup.Name) | Job: $($backup.JobName) | Type: $rawType | Platform: $rawPlatform | Total points: $($allPoints.Count)"

        $groups = $allPoints | Group-Object {
            $objId = ''
            try { if ($_.ObjectId) { $objId = $_.ObjectId.ToString() } } catch { }
            if ($objId -eq '') { $objId = '<no-objectid>' }

            $nameVal = ''
            try { $nameVal = $_.Name } catch { }
            if ($nameVal -eq '') {
                try { $nameVal = $_.VmName } catch { }
            }
            if ($nameVal -eq '') { $nameVal = '<no-name>' }

            "$objId|$nameVal"
        }

        foreach ($g in $groups) {

            $chains = Get-RestorePointChains -Points $g.Group

            Write-ReportLog "  Object: $($g.Name) | $($chains.Count) chain(s) detected"

            $chainIndex = 0
            foreach ($chain in $chains) {

                $chainIndex++

                if ($chain.IsLatestChain) {
                    Write-ReportLog "    Chain #$chainIndex Start=$($chain.ChainStart) End=$($chain.ChainEnd) Points=$($chain.Points.Count) | SKIPPED (latest chain)"
                    continue
                }

                if ($chain.FullPoint.CreationTime -ge $CutoffDate) {
                    Write-ReportLog "    Chain #$chainIndex Start=$($chain.ChainStart) End=$($chain.ChainEnd) Points=$($chain.Points.Count) | SKIPPED (full at or after cutoff)"
                    continue
                }

                Write-ReportLog "    Chain #$chainIndex Start=$($chain.ChainStart) End=$($chain.ChainEnd) Points=$($chain.Points.Count) | ELIGIBLE"

                $nameVal = ''
                try { $nameVal = $chain.FullPoint.Name } catch { }
                if ($nameVal -eq '') {
                    try { $nameVal = $chain.FullPoint.VmName } catch { }
                }
                if ($nameVal -eq '') { $nameVal = '<no-name>' }

                $fullCount = 0
                $incCount  = 0
                foreach ($p in $chain.Points) {
                    if (Test-IsFullRestorePoint -Rp $p) { $fullCount++ } else { $incCount++ }
                }

                $objIdStr = ''
                try { $objIdStr = "$($chain.FullPoint.ObjectId)" } catch { }

                # Store the chain row plus the underlying point details
                $pointDetails = New-Object System.Collections.Generic.List[object]
                foreach ($p in ($chain.Points | Sort-Object CreationTime)) {
                    $rpName = ''
                    try { $rpName = $p.Name } catch { }
                    if ($rpName -eq '') {
                        try { $rpName = $p.VmName } catch { }
                    }
                    if ($rpName -eq '') { $rpName = '<no-name>' }

                    $rpType = if (Test-IsFullRestorePoint -Rp $p) { 'Full' } else { 'Increment' }

                    $rpId = ''
                    try { $rpId = "$($p.Id)" } catch { }

                    $rpTime = $null
                    try { $rpTime = $p.CreationTime } catch { }

                    $pointDetails.Add([pscustomobject]@{
                        VMName           = $rpName
                        RestorePointTime = $rpTime
                        RestorePointType = $rpType
                        RestorePointId   = $rpId
                    }) | Out-Null
                }

                $results.Add([pscustomobject]@{
                    VMName           = $nameVal
                    JobName          = $backup.JobName
                    BackupName       = $backup.Name
                    BackupType       = $rawType
                    Platform         = $rawPlatform
                    Repository       = $repoInfo.Name
                    RepositoryType   = $repoInfo.Type
                    ChainNumber      = $chainIndex
                    ChainStart       = $chain.ChainStart
                    ChainEnd         = $chain.ChainEnd
                    FullCount        = $fullCount
                    IncrementCount   = $incCount
                    TotalChainPoints = $chain.Points.Count
                    ChainsForObject  = $chains.Count
                    ObjectId         = $objIdStr
                    PointDetails     = $pointDetails
                }) | Out-Null
            }
        }
    }
}

# ------------------------------------------------------------
# Output banner
# ------------------------------------------------------------

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "   Eligible Stale Restore Points - HPE Morpheus Report" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

if ($morpheusBackups.Count -eq 0) {

    Write-Host "No HPE Morpheus backup jobs were found." -ForegroundColor Yellow
    Write-ReportLog "RESULT: no HPE Morpheus backups detected"

    if (-not $global:WrapperConnected) {
        Disconnect-VBRServer -ErrorAction SilentlyContinue
    }
    return
}

if ($results.Count -eq 0) {

    Write-Host "HPE Morpheus jobs exist, but no eligible orphaned chains were found before the cutoff." -ForegroundColor Green
    Write-ReportLog "RESULT: no eligible chains"

    if ($encryptedBackups.Count -gt 0) {
        Write-Host ""
        Write-Host "The Following HPE Morpheus Backup Jobs Could Not Be Listed As They Are Encrypted" -ForegroundColor Yellow
        foreach ($e in $encryptedBackups) {
            Write-Host ("  {0}  ({1})" -f $e.JobName, $e.BackupName) -ForegroundColor Yellow
        }
    }

    if ($inaccessibleBackups.Count -gt 0) {
        Write-Host ""
        Write-Host "The Following HPE Morpheus Backup Jobs Could Not Be Listed" -ForegroundColor DarkYellow
        foreach ($i in $inaccessibleBackups) {
            Write-Host ("  {0}  ({1})" -f $i.JobName, $i.BackupName) -ForegroundColor DarkYellow
        }
    }

    if (-not $global:WrapperConnected) {
        Disconnect-VBRServer -ErrorAction SilentlyContinue
    }
    return
}

# ------------------------------------------------------------
# Interactive selection
# ------------------------------------------------------------

while ($true) {

    $cleanupMap = @{}
    $rowNum = 1

    $displayRows = foreach ($r in ($results | Sort-Object ChainStart, VMName)) {
        $cleanupMap["$rowNum"] = $r

        [pscustomobject]@{
            Row              = $rowNum
            VMName           = $r.VMName
            BackupType       = $r.BackupType
            Repository       = $r.Repository
            JobName          = $r.JobName
            ChainStart       = $r.ChainStart
            ChainEnd         = $r.ChainEnd
            Points           = "$($r.TotalChainPoints) ($($r.FullCount)F + $($r.IncrementCount)I)"
            ChainsForObject  = $r.ChainsForObject
        }

        $rowNum++
    }

    Write-Host ""
    $tableText = $displayRows | Format-Table -AutoSize | Out-String
    Write-Host $tableText

    Write-Host "Enter a row number to view that chain's restore points and optionally export to CSV." -ForegroundColor DarkGray
    Write-Host "Enter 'C' to cancel and exit." -ForegroundColor DarkGray
    Write-Host ""

    $selection = Read-Host "Selection"

    if ([string]::IsNullOrWhiteSpace($selection)) { continue }

    if ($selection -match '^(c|cancel|q|quit|exit)$') {
        Write-Host ""
        Write-Host "Cancelled. Exiting." -ForegroundColor Green
        Write-ReportLog "User cancelled at main menu"
        break
    }

    $selection = $selection.Trim()
    if (-not $cleanupMap.ContainsKey($selection)) {
        Write-Warning "Invalid row number. Try again."
        continue
    }

    $target = $cleanupMap[$selection]

    Write-Host ""
    Write-Host "Chain details:" -ForegroundColor Cyan
    Write-Host "  VMName           : $($target.VMName)"
    Write-Host "  BackupType       : $($target.BackupType)"
    Write-Host "  Platform         : $($target.Platform)"
    Write-Host "  JobName          : $($target.JobName)"
    Write-Host "  BackupName       : $($target.BackupName)"
    Write-Host "  Repository       : $($target.Repository)"
    Write-Host "  ChainStart       : $($target.ChainStart)"
    Write-Host "  ChainEnd         : $($target.ChainEnd)"
    Write-Host "  Total Chain Pts  : $($target.TotalChainPoints) ($($target.FullCount) Full + $($target.IncrementCount) Increment)"
    Write-Host "  Chains for Obj   : $($target.ChainsForObject)"

    Write-Host ""
    Write-Host "Eligible restore points in this chain:" -ForegroundColor Cyan

    $pointsTable = $target.PointDetails |
        Sort-Object RestorePointTime |
        Select-Object VMName, RestorePointTime, RestorePointType, RestorePointId |
        Format-Table -AutoSize | Out-String

    Write-Host $pointsTable

    Write-ReportLog ""
    Write-ReportLog "----- USER SELECTED CHAIN -----"
    Write-ReportLog "VMName:       $($target.VMName)"
    Write-ReportLog "BackupName:   $($target.BackupName)"
    Write-ReportLog "ChainStart:   $($target.ChainStart)"
    Write-ReportLog "ChainEnd:     $($target.ChainEnd)"
    Write-ReportLog "Points:       $($target.TotalChainPoints)"

    # ---- Export options ----
    Write-Host "Options:" -ForegroundColor Cyan
    Write-Host "  Enter a filename to export this chain's restore points to C:\Temp\<filename>.csv"
    Write-Host "  Enter 'C' to cancel and return to the chain list"
    Write-Host ""

    $exportInput = Read-Host "Filename or 'C' to cancel"

    if ([string]::IsNullOrWhiteSpace($exportInput)) {
        Write-Host "No input. Returning to list." -ForegroundColor DarkGray
        continue
    }

    if ($exportInput -match '^(c|cancel)$') {
        Write-Host "Export cancelled. Returning to list." -ForegroundColor Green
        Write-ReportLog "Export cancelled by user"
        continue
    }

    # Sanitize filename
    $filename = $exportInput.Trim()

    # Strip any directory prefix the user typed
    $filename = Split-Path -Path $filename -Leaf

    # Remove invalid filename characters
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($ch in $invalidChars) {
        $filename = $filename.Replace($ch, '_')
    }

    # Append .csv if not already there
    if ($filename -notmatch '\.csv$') {
        $filename = "$filename.csv"
    }

    $exportPath = Join-Path 'C:\Temp' $filename

    # Make sure C:\Temp exists
    if (-not (Test-Path 'C:\Temp')) {
        try {
            New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null
        } catch {
            Write-Warning "Could not create C:\Temp: $_"
            continue
        }
    }

    # Build the export records
    $exportRows = foreach ($p in ($target.PointDetails | Sort-Object RestorePointTime)) {
        [pscustomobject]@{
            VMName           = $target.VMName
            JobName          = $target.JobName
            BackupName       = $target.BackupName
            BackupType       = $target.BackupType
            Platform         = $target.Platform
            Repository       = $target.Repository
            ChainStart       = $target.ChainStart
            ChainEnd         = $target.ChainEnd
            ChainPointCount  = $target.TotalChainPoints
            RestorePointTime = $p.RestorePointTime
            RestorePointType = $p.RestorePointType
            RestorePointId   = $p.RestorePointId
            ObjectId         = $target.ObjectId
        }
    }

    try {
        $exportRows | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
        Write-Host ""
        Write-Host "Exported $($exportRows.Count) restore point(s) to:" -ForegroundColor Green
        Write-Host "  $exportPath" -ForegroundColor Green
        Write-ReportLog "Exported $($exportRows.Count) points to $exportPath"
    } catch {
        Write-Warning "Failed to write CSV: $_"
        Write-ReportLog "FAILED to write CSV: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# Show encrypted / inaccessible at the end if any
# ------------------------------------------------------------

if ($encryptedBackups.Count -gt 0) {
    Write-Host ""
    Write-Host "The Following HPE Morpheus Backup Jobs Could Not Be Listed As They Are Encrypted" -ForegroundColor Yellow
    foreach ($e in $encryptedBackups) {
        Write-Host ("  {0}  ({1})" -f $e.JobName, $e.BackupName) -ForegroundColor Yellow
    }
}

if ($inaccessibleBackups.Count -gt 0) {
    Write-Host ""
    Write-Host "The Following HPE Morpheus Backup Jobs Could Not Be Listed" -ForegroundColor DarkYellow
    foreach ($i in $inaccessibleBackups) {
        Write-Host ("  {0}  ({1})" -f $i.JobName, $i.BackupName) -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "Session complete." -ForegroundColor Green
Write-Host "Detailed log: $LogPath" -ForegroundColor DarkGray
Write-ReportLog "===== Session Ended ====="

if (-not $global:WrapperConnected) {
    Disconnect-VBRServer -ErrorAction SilentlyContinue
}