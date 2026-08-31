# Build: Bench Cleanup Runner

## Context

I run a computer repair shop. Techs carry a Ventoy USB stick to customer machines and
run a cleanup as part of a $100 service. I want a PowerShell script on that stick that
chains the unattended maintenance and scanning tasks, then prints a parsed summary the
tech copies onto the paper work order by hand.

The repo lives on GitHub. The USB folder is a clone, so techs can pull updates directly
onto the stick.

**Environment:** customer machines running Windows 10 and Windows 11, Windows PowerShell
5.1 (NOT PowerShell 7 - do not assume it exists). No internet guaranteed on the target
machine. No modules to install. Everything must work from a stock Windows install plus
what is on the stick.

## Deliverables

1. `Invoke-Cleanup.ps1` - the main script
2. `Run-Cleanup.cmd` - double-click launcher
3. `Update-FromGitHub.ps1` + `Run-Update.cmd` - refresh the stick from the repo
4. `README.md` - what each file does, USB folder layout, how to update
5. `SOP-Cleanup.md` - the tech-facing procedure, written as numbered steps

## Hard requirements

These are non-negotiable and each one comes from a real failure. Do not skip any.

- **Encoding: pure ASCII, CRLF line endings, UTF-8 BOM.** No box-drawing characters,
  no em-dashes, no smart quotes. PowerShell 5.1 reads .ps1 files as ANSI without a BOM,
  and any non-ASCII byte produces a cascade of parse errors.
- **Never use `$PSScriptRoot` in a `param()` block default.** It is not reliably populated
  while parameter defaults evaluate. Resolve paths after the param block from
  `$PSCommandPath`, then `$MyInvocation.MyCommand.Path`, then `Get-Location`.
- **Never assign to `$args`.** It is an automatic variable and behaves inconsistently
  inside a `[CmdletBinding()]` script.
- **The `.cmd` launcher handles elevation and execution policy**, passing
  `-NoProfile -ExecutionPolicy Bypass -File`, and ends with `pause` so the window survives
  even a syntax error. Never rely on PowerShell's `-NoExit` alone; an `exit` in the script
  closes the window regardless.
- **Disable console QuickEdit at startup** via `SetConsoleMode` P/Invoke (clear
  `ENABLE_QUICK_EDIT_MODE 0x0040`, set `ENABLE_EXTENDED_FLAGS 0x0080`). A stray click
  otherwise puts the console in selection mode and blocks the script indefinitely.
- **Write nothing to the USB during the run.** The stick can drop off the bus mid-run and
  invalidate open file handles. Work under `%TEMP%`. Wrap every file write in try/catch so
  a logging failure can never abort a scan.
- **Wrap the whole body in try/catch/finally.** The catch prints the exception message,
  line number and stack trace. The finally always pauses.
- **Every timeout must be reachable.** If you drain a process output queue in a loop, bound
  it (e.g. 2000 lines per pass) so the loop returns to the timeout check. A chatty tool
  otherwise starves it.

## Step sequence

Run in this order. Each step is independent: a failure records and moves on, never aborts
the run. Show a progress indicator per step and an overall "step N of M".

| # | Step | Command | Parse for |
|---|------|---------|-----------|
| 1 | Drive health gate | `Get-PhysicalDisk`, and SMART via `Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus` | HealthStatus, OperationalStatus, PredictFailure |
| 2 | Restore point | `Checkpoint-Computer -Description "Pre-Cleanup" -RestorePointType MODIFY_SETTINGS` | success/failure |
| 3 | Temp cleanup | Native PowerShell delete: `%TEMP%`, `C:\Windows\Temp`, `C:\Windows\Prefetch`, recycle bin | bytes freed, files deleted |
| 4 | Definition update | `Update-MpSignature` | signature version before/after |
| 5 | Defender full scan | `Start-MpScan -ScanType FullScan` | detections via `Get-MpThreatDetection` filtered to this run |
| 6 | Disk check | `chkdsk C: /scan` | errors found / clean |
| 7 | DISM | `Dism.exe /Online /Cleanup-Image /RestoreHealth` | "restore operation completed successfully", error codes, real % progress |
| 8 | SFC | `sfc.exe /scannow` | "did not find any integrity violations" / "successfully repaired" / "unable to fix", real % progress |

### Step-specific notes

- **Step 1 is a gate.** If the drive reports failure or a SMART failure prediction, STOP and
  print a prominent warning that the ticket should become a drive replacement conversation
  before burning hours of bench time. Require the tech to type `CONTINUE` to proceed anyway.
- **Do not touch PUA settings.** Modern Windows enables PUA protection by default, and
  changing it persistently alters the customer's configuration. Instead, READ
  `(Get-MpPreference).PUAProtection` and report it (0 off / 1 block / 2 audit) so the tech
  knows whether the scan covered PUAs.
- **Detect passive-mode Defender before step 5.** Read
  `(Get-MpComputerStatus).AMRunningMode` and check `root\SecurityCenter2 AntiVirusProduct`
  for third-party AV. In passive mode Defender still scans and detects but does NOT
  remediate. Report this clearly - a CLEAN result from passive Defender is not the same
  assurance as one from an active scan.
- **`chkdsk /scan`** is the online variant. It needs no reboot and must not be given `/f`
  or `/r`, which would schedule a reboot-time check.
- **DISM emits progress with carriage returns, not newlines.** If you capture its output,
  read raw characters and treat both CR and LF as line terminators, or the read blocks.
- **SFC writes UTF-16 to stdout.** Set `StandardOutputEncoding` to Unicode for that process
  or the captured text is unreadable.

## Output

At the end, print a screen block the tech copies onto the work order by hand. Nothing needs
saving to disk - this is display only. Keep it dense and scannable, no more than roughly one
screen. Include:

- Machine name, Windows version, date, total run time
- One line per step: name, status, duration, and the single most useful number or verdict
- A findings section listing anything detected, repaired, or needing review
- A clear overall verdict line at the end
- Any warnings the tech must relay to the customer (failing drive, passive Defender,
  unrepaired corruption, pending reboot)

Use colour: green for clean/OK, yellow for review, red for threats or failures.

## Post-script manual checklist

After the automated portion, print a numbered checklist of the steps a tech performs by
hand, because each needs human judgement. Keep it on screen until dismissed.

1. **ClamAV scan** - `freshclam.exe` first, then `clamscan.exe -r -i --database=<path>`
   against `C:\Users`, `C:\ProgramData` and `C:\Windows\Temp`. Exclude OneDrive (Files
   On-Demand placeholders hydrate when scanned and download the customer's whole cloud
   drive) and the legacy junctions `Application Data`, `Local Settings`, `All Users`,
   `Documents and Settings`, which loop infinitely under recursive scanning.
2. **Autoruns** (Sysinternals GUI) - enable Check VirusTotal and Hide Microsoft Entries,
   review what remains.
3. **Process Explorer** - VirusTotal column, review running processes.
4. **BleachBit** (portable) - browser cache and temp only. Never cookies, passwords or
   history; wiping a customer's logged-in sessions turns a cleanup into a callback.
5. **Defender Offline scan** - Windows Security > Scan options > Microsoft Defender
   Antivirus (offline scan). Reboots, ~15 min. Only step that inspects the disk with
   malware not running.
6. **Browser extension review** - all installed browsers.
7. **Reboot and confirm** the machine is stable before release.

## Update mechanism

`Update-FromGitHub.ps1` refreshes the stick. Use `git pull` when git is available, and fall
back to downloading the repo zip and extracting over the folder when it is not - techs'
bench machines may not have git. Preserve any local `Tools\` folder containing downloaded
binaries; those are gitignored and must not be wiped by an update.

Add a `.gitignore` for `Tools\`, `*.log`, and any downloaded executables.

## Style

- Comment the *why*, not the *what*. Where a line exists because of a specific failure mode,
  say which one.
- Prefer clear sequential code over cleverness. A bench tech may need to read this.
- No external dependencies. No modules. Nothing that needs installing on a customer machine.
