
<h1 align="center">STALE RESTORE-POINT REPORT FOR VEEAM BACKUPS</h1>


<p align="center">
  <a href="https://github.com/STTGL-01/Stale_Restore_Point_Locator_for_Veeam_Backups">
    <strong>Download Latest Release</strong>
  </a>
  ·
  <a href="https://github.com/STTGL-01/Stale_Restore_Point_Locator_for_Veeam_Backups">
    <strong>Report an Issue</strong>
  </a>
</p>

---

> [!NOTE]
> This is an unofficial community tool. It is not developed, supported, or endorsed by Veeam Software.
> No warranty is provided. Use at your own risk.

---



## STALE RESTORE-POINT REPORT TOOLKIT for VEEAM BACKUPS

A modular PowerShell toolkit for identifying stale restore points across multiple Veeam Backup & Replication workloads and exporting findings to CSV for further review.

The toolkit uses a centralized launcher that:
- Establishes a single connection to a VBR or VSA server
- Prompts once for a cutoff date
- Executes workload-specific report scripts on demand

You connect once and define the cutoff once — all workloads reuse that session.

> [!IMPORTANT]
> This toolkit performs **reporting only**. It does not delete or modify any restore points.
> Use the generated CSV files as a reference, then perform any cleanup through the Veeam Console where chain dependencies and storage relationships are fully visible.

---

## Document Information

- **Toolkit Name:** Stale Restore-Point Report for Veeam Backups
- **Maintainer:** Zach Chamberlin
- **Version:** 1.0.1
- **Last Updated:** 2026-06-25

### Notes

- Validate the target workload before exporting reports
- Review CSV output before taking any action through the Veeam Console
- Enable diagnostic logging by reviewing the per-workload log file
- Always test in non-production environments before running against live VBR/VSA systems

---

## Table of Contents

1. What This Toolkit Does
2. Folder Layout
3. Supported Workloads
4. Prerequisites
5. Running the Toolkit
6. Cutoff Date Behavior
7. Workload Execution Flow
8. Standalone Usage
9. CSV Output Files
10. Safety Features
11. Logging
12. Troubleshooting
13. Extending the Toolkit
14. Best Practices

---

## What This Toolkit Does

For each supported workload, the toolkit:

1. Scans all backup jobs of that workload type
2. Identifies eligible orphaned restore-point chains older than the cutoff date
3. Displays an interactive selection menu of eligible chains
4. Shows the individual restore points within a selected chain
5. Allows on-demand CSV export with a user-supplied filename

**No restore points are deleted or modified by this toolkit.**
Restore points equal to or newer than the cutoff date are never included in the report.

---

## Folder Layout

```text
Veeam_Stale_Restore_Point_Report
│
├── README.md
├── Report-Launcher.ps1
└── Report_Scripts
    ├── Stale_VMware_Report.ps1
    ├── Stale_Proxmox_Report.ps1
    ├── Stale_VAW_VAL_Report.ps1
    ├── Stale_Backup_Copy_Report.ps1
    ├── Stale_HPE_Morpheus_Report.ps1
    ├── Stale_HyperV_Report.ps1
    └── Stale_Nutanix_AHV_Report.ps1
```
---

## Supported Workloads

| Option | Workload       | Description                          |
|--------|--------------|--------------------------------------|
| 1      | VMware       | VMware vSphere backups              |
| 2      | Proxmox      | Proxmox VE backups                  |
| 3      | Veeam Agent  | Windows & Linux agent backups       |
| 4      | Backup Copy  | Backup Copy job restore points      |
| 5      | HPE Morpheus | Morpheus VME backups                |
| 6      | Hyper-V      | Microsoft Hyper-V backups           |
| 7      | Nutanix AHV  | Nutanix AHV backups                 |

Each workload script is modular and follows a consistent structure.

---

## Prerequisites

- Veeam Backup & Replication PowerShell module (included with Veeam Console)  
- Network access to the VBR / VSA server  
- Credentials with sufficient permissions  
- PowerShell 7 (V13 recommended)  

If scripts are blocked after download:

```powershell
Get-ChildItem 'C:\path\to\Stale_Restore_Point_Locator_for_Veeam_Backups' -Recurse -Filter *.ps1 | Unblock-File
```

---

## Running the Toolkit

```powershell
.\Report-Launcher.ps1
```
You will be prompted for:

- Target type (VSA / Windows VBR)
- Server address (FQDN or IP)
- Credentials (secure, not stored)
- Cutoff date (yyyy-MM-dd, or Enter for today)

You will then be presented with a workload selection menu. After choosing a workload, the script will display a list of eligible orphaned chains. From there, you can select any chain to view its restore points and optionally export them to a CSV file under C:\Temp\.

---

## Cutoff Date Behavior

The cutoff date is exclusive.
Restore points are considered stale only if created before the cutoff date.
Example with cutoff 2026-06-19:

✅ 2026-06-18 → Stale
❌ 2026-06-19 → Not stale
❌ 2026-06-20 → Not stale

This ensures same-day restore points are always protected from being flagged.
Additionally, the toolkit detects restore-point chains by walking through restore points chronologically. Each Full backup starts a new chain, with any subsequent incrementals belonging to that chain. The most recent (latest) chain for any object is always excluded from results, regardless of the cutoff date.

---

## Workload Execution Flow

Each workload script performs:

1. Backup enumeration
2. Restore-point retrieval (workload-specific methods)
3. Chain detection — each Full begins a new chain
4. Latest chain protection — the most recent chain per object is excluded
5. Cutoff filtering — chains whose Full predates the cutoff are eligible
6. Interactive selection menu of eligible chains
7. Per-chain restore-point detail view
8. Optional CSV export with custom filename

If no eligible chains are found, the script reports this and exits without writing any files.

---

## Standalone Usage

Each script can run independently of the launcher:

- Prompts for connection details if not already connected
- Uses the script's local $CutoffDate value as a fallback
  
This is useful for targeted reporting or scheduled operations.
The script detects whether the launcher already connected by checking $global:WrapperConnected. If the launcher hasn't set it, the script behaves like a fully self-contained tool.

---

## CSV Output Files

Reports are written to:

```
C:\Temp\
```

Each export uses a filename you provide at the export prompt (the .csv extension is added automatically if missing). Invalid filename characters are sanitized.
Each CSV row represents one individual restore point and includes fields such as:

- VMName / ComputerName / ObjectName (depending on workload)
- JobName
- BackupName
- BackupType
- Platform
- Repository
- ChainStart / ChainEnd
- ChainPointCount
- RestorePointTime
- RestorePointType (Full or Increment)
- RestorePointId
- ObjectId

CSV files are only created when you explicitly request an export for a specific chain. No CSVs are written automatically during the scan phase.

---

## Safety Features

- **Report-only behavior** — no modifications are made to Veeam at any time
- **Latest chain always protected** — the most recent chain per object is never included in eligible results
- **Strict cutoff enforcemen**t — restore points equal to or newer than the cutoff are never flagged
- **Per-object selection** — you choose which chain to inspect or export
- **No automatic CSV writes** — exports only occur when you supply a filename
- **Cancellation at any prompt** — typing C or pressing Enter without a filename cancels safely

---

## Logging

Each workload script writes a detailed run log under C:\Temp\ with names like:

- VMware_Report_Log.txt
- Proxmox_Report_Log.txt
- Agent_Report_Log.txt
- BackupCopy_Report_Log.txt
- Morpheus_Report_Log.txt
- HyperV_Report_Log.txt
- Nutanix_Report_Log.txt

Each log captures:

- Backups detected
- Per-object chain breakdowns
- Skipped chains (with reasons such as latest chain or cutoff)
- Eligible chains
- User selections and CSV export actions

Logs are overwritten at the start of each run.

---

## Troubleshooting

**Module not found**
Install Veeam Console on the machine running the script.
**Connection issues**
Verify server FQDN/IP, credentials, port (443 for VSA, 9392 for Windows VBR), and network connectivity.
**Scripts not recognized as cmdlets**
Unblock the files using Unblock-File.
**Workload reports no backups**
Confirm that backups of that type exist on the VBR server. Check the log file for raw detection output.
**Eligible chains not appearing as expected**

- Confirm the cutoff date is correct (especially the year, which is a common slip-up)
- Remember that the latest chain per object is always excluded
- Review the log to see how the script categorized each chain (eligible vs. skipped)

**Stale items missing from CSV**
The CSV only contains restore points belonging to chains you explicitly export. Each export is per-chain.

---

## Extending the Toolkit

To add a new workload type:

1. Copy an existing report script (Hyper-V or VMware are good simple templates)
2. Update the detection logic at the top of the script (the Where-Object filter for Get-VBRBackup)
3. Update the workload-specific retrieval function (e.g., Get-WorkloadRestorePoints)
4. Update banner text and log filename
5. Add an entry to the launcher's $ScriptMap

That's it — the launcher will pick up the new script automatically.

---

## Best Practices

- **Start with a conservative cutoff date** — for example, "anything older than 30 days"
- **Review CSV exports carefully** before performing any cleanup through the Veeam Console
- **Use the Veeam Console for actual deletion** — it has visibility into chain dependencies and storage relationships that PowerShell cannot expose
- **Run during low-activity windows** to avoid contention with active backup jobs
- **Maintain configuration and data backups** before performing cleanup actions on restore-point data
- **Check the log file after each run** to confirm what the script detected and classified
