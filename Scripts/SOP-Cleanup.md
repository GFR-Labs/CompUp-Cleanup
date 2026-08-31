# SOP: Bench Cleanup ($100 service)

Tech-facing procedure. Follow the numbers; do not skip or reorder. The
automated portion does the waiting for you - your judgement is needed at the
gate, at the summary, and in the manual checklist.

> **On the bench, before you head out:** double-click `Update.cmd` on the
> stick to pull the current version, and run `Tools\ClamAV\freshclam.exe` to
> refresh virus definitions. Both need internet, so neither can be done at
> the customer machine.

## Before you start

1. Confirm the work order covers a cleanup and note any customer remarks
   (slowness, popups, "a virus"). Symptoms guide the manual review later.
2. Plug in the shop USB stick. If the machine will not boot or the drive is
   making noises, STOP - that is a diagnostics/recovery ticket, not a
   cleanup.
3. Plug the machine into mains power. A sleep or battery death mid-scan
   invalidates the run.
4. If a laptop lid is involved: Control Panel > Power Options > set lid
   close to "Do nothing" for the duration, and set it back before release.

## Automated portion

5. Open the stick folder and double-click `Run-Cleanup.cmd`. Accept the UAC
   prompt.
6. **Drive health gate (step 1).** If a red DRIVE HEALTH WARNING appears,
   stop and take the ticket to the service writer: a failing drive should
   become a drive replacement conversation BEFORE bench hours are spent.
   Only type `CONTINUE` if the service writer says to proceed; type `STOP`
   to end the run.
7. Let the run go. The Defender full scan is the long step (often 1-3
   hours); the window shows elapsed time and per-step progress. Do not
   click inside the console window while it runs.
8. If the run stops with a red FATAL ERROR, photograph the screen (message,
   line number) and report it - do not just rerun and hope.

## After the automated portion

9. **Copy the summary block onto the paper work order by hand**: machine
   name, one line per step, findings, warnings, and the verdict line.
   Nothing is saved anywhere for you - the screen is the record.
10. Read the WARNINGS section out loud to yourself. Every line there must
    be relayed to the customer (failing drive, passive-mode Defender,
    unrepaired corruption, pending reboot).

## Manual checklist (needs your judgement)

These are not printed on screen - the script ends at the summary - so work
them from this document.

11. **ClamAV**: run `Tools\ClamAV\freshclam.exe`, then scan `C:\Users`,
    `C:\ProgramData`, `C:\Windows\Temp` with `clamscan.exe -r -i
    --database=<stick>\Tools\ClamAV\db`. Exclude OneDrive folders (Files
    On-Demand placeholders hydrate when scanned and download the
    customer's entire cloud drive) and the legacy junctions `Application
    Data`, `Local Settings`, `All Users`, `Documents and Settings` (they
    loop forever under recursion).
12. **Autoruns** (`Tools\Sysinternals\Autoruns.exe`): Options > Check
    VirusTotal, Hide Microsoft Entries. Review everything that remains;
    research anything you do not recognize before deleting it.
13. **Process Explorer** (`Tools\Sysinternals\procexp.exe`): enable the
    VirusTotal column, review running processes.
14. **BleachBit** (`Tools\BleachBit\`): browser cache and temp ONLY. Never
    cookies, saved passwords, or history - wiping the customer's logged-in
    sessions turns a cleanup into a callback.
15. **Defender Offline scan**: Windows Security > Virus and threat
    protection > Scan options > Microsoft Defender Antivirus (offline
    scan). The machine reboots and scans for about 15 minutes. This is the
    only step that inspects the disk while any malware is not running.
16. **Browser extensions**: review the extension list in every installed
    browser. Remove anything the customer did not choose (search
    hijackers, "coupon" toolbars) - note removals on the work order.
17. **Reboot and confirm stable**: full reboot, log in, open a browser and
    File Explorer, check that AV is active (Windows Security shows green).
    Undo any lid/power changes from step 4.

## Release

18. Verdict CLEAN and checklist clear: note "cleanup complete" and release.
19. Verdict REVIEW or ATTENTION: talk to the service writer before release.
    Threats found, unrepaired corruption, or a failing drive may mean a
    follow-up ticket or a replacement conversation - that call is not made
    at the bench.
