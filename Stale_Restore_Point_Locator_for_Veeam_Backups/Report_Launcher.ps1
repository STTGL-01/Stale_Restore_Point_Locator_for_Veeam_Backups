# ============================================================
# Stale Restore Point Launcher
# ============================================================

# ---- Auto-detect script root (works from any folder) ----
$ScriptsSubfolder = 'Locator_Scripts'   # subfolder name (change here if you rename it)

if ($PSScriptRoot) {
    $scriptRoot = Join-Path $PSScriptRoot $ScriptsSubfolder
}
elseif ($MyInvocation.MyCommand.Path) {
    $scriptRoot = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) $ScriptsSubfolder
}
else {
    $scriptRoot = Join-Path (Get-Location).Path $ScriptsSubfolder
}


# ✅ Define the logo function HERE


function Show-Logo {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor DarkGray
    Write-Host "  ║                                                  ║" -ForegroundColor DarkGray

    Write-Host "  ║" -ForegroundColor DarkGray -NoNewline
    Write-Host "  Stale Restore Point Locator for Veeam Backups   " -ForegroundColor Green -NoNewline
    Write-Host "║" -ForegroundColor DarkGray

    Write-Host "  ║                                                  ║" -ForegroundColor DarkGray
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Maintainer: Zach Chamberlin" -ForegroundColor Cyan
    Write-Host "  Last Updated: 2026-06-23" -ForegroundColor Cyan
    Write-Host "  Version: 1.0.0" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ""
    Write-Host "  This is an unofficial community tool and is not developed, supported, or endorsed by Veeam Software" -ForegroundColor DarkYellow
    Write-Host "  use at your own risk" -ForegroundColor DarkYellow
    Write-Host ""
}



# ✅ Call it HERE - right before everything else starts
Show-Logo



Write-Host "Script root: $scriptRoot" -ForegroundColor DarkGray

# Map menu options to the actual filenames in your folder
$ScriptMap = @{
    '1' = @{ Label = 'VMware';      File = 'Locate_Stale_VMware_Backups.ps1' }
    '2' = @{ Label = 'Proxmox';     File = 'Locate_Stale_Proxmox_Backups.ps1' }
    '3' = @{ Label = 'VAW & VAL';       File = 'Locate_Stale_VAW_VAL_Backups.ps1' }
    '4' = @{ Label = 'Backup Copy'; File = 'Locate_Stale_Backup_Copies.ps1' }
    '5' = @{ Label = 'HPE Morpheus';    File = 'Locate_Stale_HPE_Morpheus_Backups.ps1' }
    '6' = @{ Label = 'Hyper-V';    File = 'Locate_Stale_Hyper-V_Backups.ps1' }
    '7' = @{ Label = 'Nutanix AHV';    File = 'Locate_Stale_Nutanix_AHV_Backups.ps1' }
}

# ---- Load Veeam module ----
try {
    Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
}
catch {
    throw "Could not load Veeam.Backup.PowerShell module: $_"
}

if (-not (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue)) {
    throw "Veeam PowerShell is not available in this session."
}

if (-not (Test-Path $scriptRoot)) {
    throw "Cleanup scripts folder not found: $scriptRoot"
}

# ------------------------------------------------------------
# Connect to VBR / VSA (once)
# ------------------------------------------------------------

if (-not (Get-VBRServerSession -ErrorAction SilentlyContinue)) {

    Write-Host ""
    Write-Host "Target type:" -ForegroundColor Cyan
    Write-Host "  [1] VSA / v13 appliance   (port 443)"
    Write-Host "  [2] Windows VBR server    (port 9392)"

    $VbrType = ''
    while ($VbrType -notin @('1','2')) {
        $VbrType = (Read-Host "Select 1 or 2").Trim()
    }

    $VbrPort   = if ($VbrType -eq '1') { 443 } else { 9392 }
    $VbrServer = (Read-Host "Enter VBR/VSA FQDN or IP").Trim()

    if (-not $VbrServer) {
        throw "No server entered."
    }

    $cred = Get-Credential -Message "Credentials for $VbrServer"

    Connect-VBRServer -Server $VbrServer -Port $VbrPort -Credential $cred -ErrorAction Stop

    # Tell child scripts a connection is already in place
    $global:WrapperConnected = $true

    Write-Host ""
    Write-Host "Connected to $VbrServer (port $VbrPort)" -ForegroundColor Green
}
else {

    # Tell child scripts a connection is already in place
    $global:WrapperConnected = $true

    Write-Host "Using existing VBR session." -ForegroundColor Green
}

# ------------------------------------------------------------
# Cutoff date prompt (shared across all child scripts)
# ------------------------------------------------------------

$today = (Get-Date).ToString('yyyy-MM-dd')

Write-Host ""
Write-Host "Enter the cutoff date (anything older than this is considered stale)." -ForegroundColor Cyan
Write-Host "Format: yyyy-MM-dd  (press Enter for today: $today)" -ForegroundColor DarkGray

while ($true) {
    $dateInput = (Read-Host "Cutoff date").Trim()

    if (-not $dateInput) {
        $dateInput = $today
    }

    try {
        $global:WrapperCutoffDate = [datetime]$dateInput
        break
    }
    catch {
        Write-Warning "Invalid date format. Use yyyy-MM-dd (example: 2026-06-19)."
    }
}

Write-Host ""
Write-Host "Cutoff date set to: $($global:WrapperCutoffDate.ToString('yyyy-MM-dd'))" -ForegroundColor Green

# ------------------------------------------------------------
# Workload selection menu
# ------------------------------------------------------------

$exitRequested = $false

while (-not $exitRequested) {

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "   Stale Restore Point Locator — Select a Workload" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""
    foreach ($key in ($ScriptMap.Keys | Sort-Object)) {
        Write-Host ("  {0}. {1}" -f $key, $ScriptMap[$key].Label)
    }
    Write-Host ""
    Write-Host "  D. Change cutoff date  (current: $($global:WrapperCutoffDate.ToString('yyyy-MM-dd')))"
    Write-Host "  Q. Quit"
    Write-Host ""

    $selection = (Read-Host "Select option").Trim()

    if ($selection -match '^(q|quit|exit)$') {
        $exitRequested = $true
        continue
    }

    # Change cutoff date option
    if ($selection -match '^d$') {
        $today = (Get-Date).ToString('yyyy-MM-dd')

        Write-Host ""
        Write-Host "Current cutoff date: $($global:WrapperCutoffDate.ToString('yyyy-MM-dd'))" -ForegroundColor Cyan
        Write-Host "Enter a new cutoff date in yyyy-MM-dd format" -ForegroundColor DarkGray
        Write-Host "(press Enter to keep current, or type 'today' for $today)" -ForegroundColor DarkGray

        $dateInput = (Read-Host "New cutoff date").Trim()

        if (-not $dateInput) {
            Write-Host "Cutoff date unchanged." -ForegroundColor DarkGray
            continue
        }

        if ($dateInput -eq 'today') {
            $dateInput = $today
        }

        try {
            $global:WrapperCutoffDate = [datetime]$dateInput
            Write-Host ""
            Write-Host "Cutoff date updated to: $($global:WrapperCutoffDate.ToString('yyyy-MM-dd'))" -ForegroundColor Green
        }
        catch {
            Write-Warning "Invalid date format. Cutoff date unchanged."
        }

        continue
    }

    if (-not $ScriptMap.ContainsKey($selection)) {
        Write-Warning "Invalid selection: '$selection'"
        continue
    }

    $entry    = $ScriptMap[$selection]
    $fullPath = Join-Path $scriptRoot $entry.File

    if (-not (Test-Path $fullPath)) {
        Write-Warning "$($entry.Label) script not found: $fullPath"
        continue
    }

    Write-Host ""
    Write-Host "Launching $($entry.Label) reporter..." -ForegroundColor Cyan
    Write-Host ""

    try {
        & $fullPath
    }
    catch {
        Write-Warning "$($entry.Label) script failed: $_"
    }

    Write-Host ""
    Write-Host "Returned to main menu." -ForegroundColor DarkGray
}

# ------------------------------------------------------------
# Disconnect and clear globals
# ------------------------------------------------------------

Write-Host ""
Write-Host "Disconnecting from VBR..." -ForegroundColor Cyan
Disconnect-VBRServer -ErrorAction SilentlyContinue

# Clear the flags so the next session starts fresh
Remove-Variable -Name WrapperConnected  -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name WrapperCutoffDate -Scope Global -ErrorAction SilentlyContinue

Write-Host "Session ended." -ForegroundColor Green