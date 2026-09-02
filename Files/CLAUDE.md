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

1. `Scripts/Invoke-Cleanup.ps1` - the main script
2. `Run-Cleanup.cmd` - double-click launcher
3. `Update.cmd` - single self-contained file that refreshes the stick from the repo
3b. `Scripts/Scan-Clam.cmd` + `Scripts/Scan-Clam.ps1` - standalone ClamAV re-scan of one
    path, for use after remediating what the cleanup run found. NOT a standard-job file,
    which is why it is not at the root.
4. `README.md` - what each file does, USB folder layout, how to update
5. `Scripts/SOP-Cleanup.md` - the tech-facing procedure, written as numbered steps

### Folder layout

Only the two double-clickable launchers sit at the repo/stick root; everything else
lives in `Scripts\`, and the docs in `Files\`. The extracted ClamAV build lives in
`ClamAV\` at the stick root, OUTSIDE the repo and gitignored - it is the only thing on
a stick that is not in the repo. Keep both launchers INSIDE the repo - moving them
outside the clone means `git pull` can never update them again.

Three places encode this layout and must change together: `Run-Cleanup.cmd` resolves
`%~dp0Scripts\Invoke-Cleanup.ps1`, `Scripts\Scan-Clam.cmd` resolves `%~dp0Scan-Clam.ps1`
(both are in `Scripts\`), and `Update.cmd` uses the first of those as its "is this a
cleanup stick" sentinel. Only the two launchers a tech runs on a normal job -
`Run-Cleanup.cmd` and `Update.cmd` - belong at the root.

`.gitattributes` and `.gitignore` MUST stay at the repo root. Both only apply from
their own directory down, so a copy under `Files\` protects `Files\` alone and leaves
the root launchers and `Scripts\*.ps1` exposed to line-ending renormalization, which
silently strips the CRLF and BOM the scripts depend on.

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
| 4 | Browser caches | Native delete across EVERY profile in `C:\Users`: Chrome/Edge/Brave `Cache` and `Code Cache`, Firefox `cache2`, `thumbcache_*.db`, `INetCache` | bytes freed per category |
| 5 | ClamAV definitions | `freshclam` via `Scripts/ClamAV.Lib.ps1`, update VERIFIED not trusted | version before/after, defs age |
| 6 | ClamAV scan | `clamscan` via `Scripts/ClamAV.Lib.ps1`, using step 5's definitions | infected count, FOUND lines |
| 7 | Disk check | `chkdsk C: /scan` | errors found / clean |
| 8 | DISM | `Dism.exe /Online /Cleanup-Image /RestoreHealth` | "restore operation completed successfully", error codes, real % progress |
| 9 | Component cleanup | `Dism.exe /Online /Cleanup-Image /StartComponentCleanup` | free-space delta, real % progress |
| 10 | Windows disk cleanup | `cleanmgr /sagerun:1 /d C:` after setting `StateFlags0001` | free-space delta, elapsed time |
| 11 | SFC | `sfc.exe /scannow` | "did not find any integrity violations" / "successfully repaired" / "unable to fix", real % progress |

SFC runs LAST so it verifies integrity after the cleanup steps have finished
removing components.

### Step-specific notes

- **Step 1 is a gate.** If the drive reports failure or a SMART failure prediction, STOP and
  print a prominent warning that the ticket should become a drive replacement conversation
  before burning hours of bench time. Require the tech to type `CONTINUE` to proceed anyway.
- **Do not touch PUA settings.** Modern Windows enables PUA protection by default, and
  changing it persistently alters the customer's configuration. Instead, READ
  `(Get-MpPreference).PUAProtection` and report it (0 off / 1 block / 2 audit) so the tech
  knows whether the scan covered PUAs.
- **Detect passive-mode Defender before the full scan.** Read
  `(Get-MpComputerStatus).AMRunningMode` and check `root\SecurityCenter2 AntiVirusProduct`
  for third-party AV. In passive mode Defender still scans and detects but does NOT
  remediate. Report this clearly - a CLEAN result from passive Defender is not the same
  assurance as one from an active scan.
- **There is NO Defender step. Do not add one back.** The full scan is manual (see
  below), and Windows Security updates its own definitions when the tech runs it, so
  an `Update-MpSignature` step in this script buys nothing. The passive-mode and PUA
  posture check is still made - once, at startup, not as a step - because the tech
  needs to know before they reach Windows Security that a passive machine will not run
  an on-demand scan until Periodic scanning is turned on.
- **Any step can be skipped mid-run: press S, then type SKIP to confirm.** Two
  deliberate actions. A single keypress would be far too easy to trigger by accident on
  steps that run for tens of minutes. The check is polled from the process runner and
  the file-deletion loops; `[Console]::KeyAvailable` throws when input is redirected, so
  a non-interactive host must simply never offer it rather than blocking.
- **The Defender FULL SCAN is manual, in the SOP - do not automate it again.** It ran
  one to three hours emitting nothing, so a slow scan and a hung one were
  indistinguishable and techs killed healthy runs. Driven by hand from Windows
  Security the tech gets a live file count. The script still updates Defender's
  definitions, so the manual scan starts current, and still reports passive mode and
  PUA state so the tech knows what to expect. ClamAV is the automated scan instead: a
  different engine, visible per-file progress, unaffected by Defender being passive.
- **ClamAV logic lives in `Scripts/ClamAV.Lib.ps1`, dot-sourced by BOTH**
  `Invoke-Cleanup.ps1` (the scan step) and `Scan-Clam.ps1` (targeted re-scan after
  remediation). Never duplicate it into one of them - they must not drift.
- **Do NOT try to promote Defender to active mode for the scan.** Windows Security
  Center decides which engine is primary; while a third-party AV is registered,
  Defender stays passive. The `ForceDefenderPassiveMode` policy only forces passive,
  never active, and the only thing that actually flips it is disabling or removing the
  other product - which changes the customer's protection and would leave them exposed
  if the script died mid-run. Instead: attempt `Remove-MpThreat` anyway, VERIFY via
  `Get-MpThreat` whether anything is still flagged active (ThreatStatusID 1), and when
  it did not work say so and point at the two things that do remediate - a full scan in
  the customer's own AV, or a Microsoft Defender Offline scan, which runs outside
  Windows where the third-party engine is not loaded.
- **Browsers may be auto-closed, but only on confirmation.** Edge keeps background
  processes running with no window, so the browser-cache step cannot just tell the tech
  to close everything. Offer a CLOSE option that calls `CloseMainWindow()` first so
  sessions are saved and tabs restore, waits, and only then force-stops what is left.
  Never kill browsers without the tech confirming - open tabs may hold unsaved work.
- **ClamAV: freshclam exiting 0 does not prove it downloaded anything.** It has
  reported the database a version behind and still returned success, and a scan on
  stale signatures that the tech believes is current is worse than no scan. So the
  library reads the database version via `sigtool --info` before and after (both
  `daily.cvd` and `daily.cld` - freshclam produces either), treats any "behind" /
  "out of date" / failure text as failure regardless of exit code, retries once after
  deleting the cvd/cld files to force a full download rather than an incremental
  patch, and only then asks the tech to type YES with the database age shown. Do NOT
  match freshclam's "Your ClamAV installation is OUTDATED" warning as a failure - that
  refers to the engine binary, not the signatures, and matching it makes every run
  demand a YES.
- **ClamAV's scan flags and exclusions are the shop's tuned set** - `--max-filesize`,
  `--max-scansize`, `--max-scantime`, `--cross-fs=no`, both `--follow-*-symlinks=0`,
  stderr kept separate and locked-file warnings counted, and `--exclude-dir` patterns
  WITHOUT `$` anchors (anchored, clamscan still descends into the directory). Do not
  simplify them.
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

## Manual checklist (SOP only - do NOT print it)

These are the steps a tech performs by hand after the automated portion, because each
needs human judgement. They belong in `Scripts/SOP-Cleanup.md` as numbered steps.

The script must NOT print them: on screen they pushed the run past one screen and buried
the summary the tech actually copies onto the work order. `Invoke-Cleanup.ps1` ends at
the summary, findings, warnings, verdict, and the run-log path.

1. **Defender full scan (manual)** - Windows Security > Virus and threat protection >
   Full scan. If the run reported Defender as PASSIVE, first turn on Microsoft Defender
   Antivirus options > Periodic scanning, or Defender will not scan on demand. That is
   a persistent change to the customer's machine; note it on the work order. In passive
   mode Defender detects but cannot remove.
2. **Remediate what ClamAV found** - it reports only. Judge each FOUND line (false
   positives are common), remove what is genuinely malicious, then re-scan that one
   path with `Scripts/Scan-Clam.cmd "C:\path"` to confirm.
3. **Autoruns** (Sysinternals GUI) - enable Check VirusTotal and Hide Microsoft Entries,
   review what remains.
4. **Process Explorer** - VirusTotal column, review running processes.
5. **BleachBit** (portable) - browser cache and temp only. Never cookies, passwords or
   history; wiping a customer's logged-in sessions turns a cleanup into a callback.
6. **Defender Offline scan** - Windows Security > Scan options > Microsoft Defender
   Antivirus (offline scan). Reboots, ~15 min. Only step that inspects the disk with
   malware not running.
7. **Browser extension review** - all installed browsers.
8. **Reboot and confirm** the machine is stable before release.

## Update mechanism

`Update.cmd` refreshes the stick, as ONE self-contained double-clickable file (the
PowerShell payload is embedded in it, below a marker line). Use `git pull` when git is
available, and fall back to downloading the repo zip and extracting over the folder when
it is not - techs' bench machines may not have git. Preserve the local `ClamAV\`
folder (and any older `Tools\`); it is gitignored and must not be wiped by an update.

The updater overwrites its own file, so it must copy itself to `%TEMP%` and re-run from
there first. cmd.exe seeks back to a saved byte offset in the batch file after each
command instead of loading it into memory, so a batch file that replaces itself mid-run
resumes at a stale offset and executes garbage.

Add a `.gitignore` for `ClamAV\`, `Tools\`, `*.log`, and any downloaded executables.

## Style

- Comment the *why*, not the *what*. Where a line exists because of a specific failure mode,
  say which one.
- Prefer clear sequential code over cleverness. A bench tech may need to read this.
- No external dependencies. No modules. Nothing that needs installing on a customer machine.
