# ============================================================
# Stale Restore-Point Report — Nutanix AHV
# Detects:
#   Nutanix AHV backups by TypeToString and Platform
# Report-only with inter Connect-VBRServer -ErrorAction SilentlyContinue)) {# Report-only with interactive selection and CSV export.

# ---- Settings ----

if ($global:WrapperCutoffDate) {
    [datetime]$CutoffDate = $global:WrapperCutoffDate
} else {
    [datetime]$CutoffDate = '2026-06-20'
}

$LogPath = 'C:\Temp\BackupCopy_Report_Log.txt'

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
Write-ReportLog "===== Nutanix AHV Report Started ====="
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

function Get-NutanixRestorePoints {
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

# ✅ Helper to build a "latest chain details" object from a chain
function Build-LatestChainDetails {
    param($Chain)

    if (-not $Chain) { return $null }

    $latestPointDetails = New-Object System.Collections.Generic.List[object]
    foreach ($p in ($Chain.Points | Sort-Object CreationTime)) {
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

        $latestPointDetails.Add([pscustomobject]@{
            VMName           = $rpName
            RestorePointTime = $rpTime
            RestorePointType = $rpType
            RestorePointId   = $rpId
        }) | Out-Null
    }

    $latestFullCount = 0
    $latestIncCount  = 0
    foreach ($p in $Chain.Points) {
        if (Test-IsFullRestorePoint -Rp $p) { $latestFullCount++ } else { $latestIncCount++ }
    }

    return [pscustomobject]@{
        ChainStart       = $Chain.ChainStart
        ChainEnd         = $Chain.ChainEnd
        FullCount        = $latestFullCount
        IncrementCount   = $latestIncCount
        TotalChainPoints = $Chain.Points.Count
        PointDetails     = $latestPointDetails
    }
}

# ------------------------------------------------------------
# Collect Nutanix AHV chains
# ------------------------------------------------------------

$results              = New-Object System.Collections.Generic.List[object]
$ineligibleOnlyRows   = New-Object System.Collections.Generic.List[object]   # ✅ ineligible chains without eligible counterparts
$encryptedBackups     = New-Object System.Collections.Generic.List[object]
$inaccessibleBackups  = New-Object System.Collections.Generic.List[object]

$nutanixBackups = @(Get-VBRBackup | Where-Object {
    $typeStr  = Get-RawType -Backup $_
    $platform = Get-RawPlatform -Backup $_

    ($typeStr  -match 'Nutanix|AHV') -or
    ($platform -match 'AHV|Nutanix')
})

Write-ReportLog "Nutanix AHV backups detected: $($nutanixBackups.Count)"

# ✅ EARLY EXIT — no Nutanix AHV backups
if ($nutanixBackups.Count -eq 0) {

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "   Stale Restore Points - Nutanix AHV Report" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "No Nutanix AHV backup jobs were found." -ForegroundColor Yellow
    Write-Host ""

    Write-ReportLog "RESULT: no Nutanix AHV backups detected"

    if (-not $global:WrapperConnected) {
        Disconnect-VBRServer -ErrorAction SilentlyContinue
    }

    return
}

foreach ($backup in $nutanixBackups) {

    $rawPlatform = Get-RawPlatform -Backup $backup
    $rawType     = Get-RawType -Backup $backup

    $repoInfo = $null
    try { $repoInfo = Resolve-RepoInfo -Repo $backup.GetRepository() }
    catch { $repoInfo = [pscustomobject]@{ Name='<error>'; Type='<error>' } }

    $allPoints = Get-NutanixRestorePoints -Backup $backup

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

        # ✅ Capture latest chain details for later display
        $latestChainObj     = $chains | Where-Object { $_.IsLatestChain } | Select-Object -First 1
        $latestChainDetails = Build-LatestChainDetails -Chain $latestChainObj

        # Object-level metadata that we'll reuse across rows
        $objectName = ''
        $sampleRp = $g.Group | Select-Object -First 1
        if ($sampleRp) {
            try { $objectName = $sampleRp.Name } catch { }
            if ($objectName -eq '') {
                try { $objectName = $sampleRp.VmName } catch { }
            }
        }
        if ($objectName -eq '') { $objectName = '<no-name>' }

        $objIdStr = ''
        if ($latestChainObj) {
            try { $objIdStr = "$($latestChainObj.FullPoint.ObjectId)" } catch { }
        }
        if ($objIdStr -eq '' -and $sampleRp) {
            try { $objIdStr = "$($sampleRp.ObjectId)" } catch { }
        }

        $eligibleChainAdded = $false

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

            $chainObjId = ''
            try { $chainObjId = "$($chain.FullPoint.ObjectId)" } catch { }

            # Store the eligible chain's underlying point details
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
                VMName             = $nameVal
                JobName            = $backup.JobName
                BackupName         = $backup.Name
                BackupType         = $rawType
                Platform           = $rawPlatform
                Repository         = $repoInfo.Name
                RepositoryType     = $repoInfo.Type
                ChainNumber        = $chainIndex
                ChainStart         = $chain.ChainStart
                ChainEnd           = $chain.ChainEnd
                FullCount          = $fullCount
                IncrementCount     = $incCount
                TotalChainPoints   = $chain.Points.Count
                ChainsForObject    = $chains.Count
                ObjectId           = $chainObjId
                PointDetails       = $pointDetails
                LatestChainDetails = $latestChainDetails
            }) | Out-Null

            $eligibleChainAdded = $true
        }

        # ✅ If this object had no eligible chains but does have a latest chain,
        # record an "ineligible-only" row so the user can still view it.
        if (-not $eligibleChainAdded -and $latestChainDetails) {

            $ineligibleOnlyRows.Add([pscustomobject]@{
                VMName             = $objectName
                JobName            = $backup.JobName
                BackupName         = $backup.Name
                BackupType         = $rawType
                Platform           = $rawPlatform
                Repository         = $repoInfo.Name
                RepositoryType     = $repoInfo.Type
                ChainsForObject    = $chains.Count
                ObjectId           = $objIdStr
                LatestChainDetails = $latestChainDetails
            }) | Out-Null

            Write-ReportLog "    Object had no eligible chains - recorded ineligible-only row"
        }
    }
}

# ------------------------------------------------------------
# Output banner
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Stale Restore Points - Nutanix AHV Report" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ✅ New behavior: if no eligible chains exist but we have ineligible-only rows,
# still let the user select them to view the current chain.
if ($results.Count -eq 0 -and $ineligibleOnlyRows.Count -eq 0) {

    Write-Host "Nutanix AHV jobs exist, but no eligible stale chains were found before the cutoff." -ForegroundColor Green
    Write-ReportLog "RESULT: no eligible chains and no ineligible-only rows"

    if ($encryptedBackups.Count -gt 0) {
        Write-Host ""
        Write-Host "The Following Nutanix AHV Backup Jobs Could Not Be Listed As They Are Encrypted" -ForegroundColor Yellow
        foreach ($e in $encryptedBackups) {
            Write-Host ("  {0}  ({1})" -f $e.JobName, $e.BackupName) -ForegroundColor Yellow
        }
    }

    if ($inaccessibleBackups.Count -gt 0) {
        Write-Host ""
        Write-Host "The Following Nutanix AHV Backup Jobs Could Not Be Listed" -ForegroundColor DarkYellow
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

    # Combine eligible rows + ineligible-only rows for selection
    $combinedRows = @()
    foreach ($r in ($results            | Sort-Object ChainStart, VMName)) { $combinedRows += $r }
    foreach ($r in ($ineligibleOnlyRows | Sort-Object VMName))             { $combinedRows += $r }

    $displayRows = foreach ($r in $combinedRows) {
        $cleanupMap["$rowNum"] = $r

        $hasEligible    = $r.PSObject.Properties['PointDetails']  -and $r.PointDetails
        $eligibleLabel  = if ($hasEligible) { "$($r.TotalChainPoints) ($($r.FullCount)F + $($r.IncrementCount)I)" } else { 'None' }
        $chainStartCol  = if ($hasEligible) { $r.ChainStart } else { '<no eligible chains>' }
        $chainEndCol    = if ($hasEligible) { $r.ChainEnd }   else { '<no eligible chains>' }

        [pscustomobject]@{
            Row              = $rowNum
            VMName           = $r.VMName
            BackupType       = $r.BackupType
            Repository       = $r.Repository
            JobName          = $r.JobName
            ChainStart       = $chainStartCol
            ChainEnd         = $chainEndCol
            EligiblePoints   = $eligibleLabel
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

    $hasEligible = $target.PSObject.Properties['PointDetails'] -and $target.PointDetails

    Write-Host ""
    Write-Host "Chain details:" -ForegroundColor Cyan
    Write-Host "  VMName           : $($target.VMName)"
    Write-Host "  BackupType       : $($target.BackupType)"
    Write-Host "  Platform         : $($target.Platform)"
    Write-Host "  JobName          : $($target.JobName)"
    Write-Host "  BackupName       : $($target.BackupName)"
    Write-Host "  Repository       : $($target.Repository)"

    if ($hasEligible) {
        Write-Host "  ChainStart       : $($target.ChainStart)"
        Write-Host "  ChainEnd         : $($target.ChainEnd)"
        Write-Host "  Total Chain Pts  : $($target.TotalChainPoints) ($($target.FullCount) Full + $($target.IncrementCount) Increment)"
    }

    Write-Host "  Chains for Obj   : $($target.ChainsForObject)"

    Write-Host ""
    Write-Host "--------------------------------------" -ForegroundColor Cyan
    Write-Host "Eligible restore points in this chain:" -ForegroundColor Cyan
    Write-Host "--------------------------------------" -ForegroundColor Cyan

    if ($hasEligible) {

        $pointsTable = $target.PointDetails |
            Sort-Object RestorePointTime |
            Select-Object VMName, RestorePointTime, RestorePointType, RestorePointId |
            Format-Table -AutoSize | Out-String

        Write-Host $pointsTable

    } else {

        # ✅ One blank line above the notice, three blank lines below
        Write-Host "Nutanix AHV exists, but no eligible chains were found before the cutoff" -ForegroundColor Green
        Write-Host ""
        Write-Host ""
        Write-Host ""
    }

    # ✅ Display the ineligible (latest/current) chain afterward
    if ($target.LatestChainDetails) {
        Write-Host "-----------------------------------------------------" -ForegroundColor Red
        Write-Host "Ineligible restore points due to being current chain:" -ForegroundColor Red
        Write-Host "-----------------------------------------------------" -ForegroundColor Red

        $latestPointsTable = $target.LatestChainDetails.PointDetails |
            Sort-Object RestorePointTime |
            Select-Object VMName, RestorePointTime, RestorePointType, RestorePointId |
            Format-Table -AutoSize | Out-String

        Write-Host $latestPointsTable
    }

    Write-ReportLog ""
    Write-ReportLog "----- USER SELECTED CHAIN -----"
    Write-ReportLog "VMName:       $($target.VMName)"
    Write-ReportLog "BackupName:   $($target.BackupName)"
    if ($hasEligible) {
        Write-ReportLog "ChainStart:   $($target.ChainStart)"
        Write-ReportLog "ChainEnd:     $($target.ChainEnd)"
        Write-ReportLog "Points:       $($target.TotalChainPoints)"
    } else {
        Write-ReportLog "Eligible chain: NONE"
    }

    # ---- Export options ----
    Write-Host "Options:" -ForegroundColor Cyan
    Write-Host "  Enter a filename to export the eligible and ineligible chains to C:\Temp\<filename>-Eligible.csv and <filename>-Ineligible.csv"
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
    $filename = Split-Path -Path $filename -Leaf

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($ch in $invalidChars) {
        $filename = $filename.Replace($ch, '_')
    }

    # Strip .csv if user added it
    if ($filename -match '\.csv$') {
        $filename = $filename -replace '\.csv$', ''
    }

    # Make sure C:\Temp exists
    if (-not (Test-Path 'C:\Temp')) {
        try {
            New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null
        } catch {
            Write-Warning "Could not create C:\Temp: $_"
            continue
        }
    }

    # ✅ Eligible CSV (only if there is one)
    if ($hasEligible) {

        $eligibleExportPath = Join-Path 'C:\Temp' "$filename-Eligible.csv"

        $eligibleRows = foreach ($p in ($target.PointDetails | Sort-Object RestorePointTime)) {
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
            $eligibleRows | Export-Csv -Path $eligibleExportPath -NoTypeInformation -Encoding UTF8
            Write-Host ""
            Write-Host "Exported $($eligibleRows.Count) eligible restore point(s) to:" -ForegroundColor Green
            Write-Host "  $eligibleExportPath" -ForegroundColor Green
            Write-ReportLog "Exported $($eligibleRows.Count) eligible points to $eligibleExportPath"
        } catch {
            Write-Warning "Failed to write eligible CSV: $_"
            Write-ReportLog "FAILED to write eligible CSV: $($_.Exception.Message)"
        }
    } else {
        Write-Host ""
        Write-Host "No eligible restore points to export — skipping eligible CSV." -ForegroundColor DarkGray
        Write-ReportLog "Skipped eligible CSV (no eligible chain)"
    }

    # ✅ Ineligible CSV (latest chain)
    if ($target.LatestChainDetails) {

        $ineligibleExportPath = Join-Path 'C:\Temp' "$filename-Ineligible.csv"

        $ineligibleRows = foreach ($p in ($target.LatestChainDetails.PointDetails | Sort-Object RestorePointTime)) {
            [pscustomobject]@{
                VMName           = $target.VMName
                JobName          = $target.JobName
                BackupName       = $target.BackupName
                BackupType       = $target.BackupType
                Platform         = $target.Platform
                Repository       = $target.Repository
                ChainStart       = $target.LatestChainDetails.ChainStart
                ChainEnd         = $target.LatestChainDetails.ChainEnd
                ChainPointCount  = $target.LatestChainDetails.TotalChainPoints
                RestorePointTime = $p.RestorePointTime
                RestorePointType = $p.RestorePointType
                RestorePointId   = $p.RestorePointId
                ObjectId         = $target.ObjectId
            }
        }

        try {
            $ineligibleRows | Export-Csv -Path $ineligibleExportPath -NoTypeInformation -Encoding UTF8
            Write-Host "Exported $($ineligibleRows.Count) ineligible restore point(s) to:" -ForegroundColor Green
            Write-Host "  $ineligibleExportPath" -ForegroundColor Green
            Write-ReportLog "Exported $($ineligibleRows.Count) ineligible points to $ineligibleExportPath"
        } catch {
            Write-Warning "Failed to write ineligible CSV: $_"
            Write-ReportLog "FAILED to write ineligible CSV: $($_.Exception.Message)"
        }
    }
}

# ------------------------------------------------------------
# Show encrypted / inaccessible at the end if any
# ------------------------------------------------------------

if ($encryptedBackups.Count -gt 0) {
    Write-Host ""
    Write-Host "The Following Nutanix AHV Backup Jobs Could Not Be Listed As They Are Encrypted" -ForegroundColor Yellow
    foreach ($e in $encryptedBackups) {
        Write-Host ("  {0}  ({1})" -f $e.JobName, $e.BackupName) -ForegroundColor Yellow
    }
}

if ($inaccessibleBackups.Count -gt 0) {
    Write-Host ""
    Write-Host "The Following Nutanix AHV Backup Jobs Could Not Be Listed" -ForegroundColor DarkYellow
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
# ============================================================

# ---- Settings ----

if ($global:WrapperCutoffDate) {
    [datetime]$CutoffDate = $global:WrapperCutoffDate
} else {
    [datetime]$CutoffDate = '2026-06-20'
}

$LogPath = 'C:\Temp\Nutanix_Report_Log.txt'

# ---- Load Veeam PowerShell ----
try {
    Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
} catch {
    throw "Could not load the Veeam.Backup.PowerShell module: $_"
}

