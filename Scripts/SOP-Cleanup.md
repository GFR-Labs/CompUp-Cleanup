# SOP: Bench Cleanup ($100 service)

Tech-facing procedure. Follow the numbers; do not skip or reorder. The
automated portion does the waiting for you - your judgement is needed at the
gate, at the summary, and in the manual checklist.

> **On the bench, before you head out:** double-click `Update.cmd` on the
> stick to pull the current version. That is the only bench step - ClamAV
> updates its own definitions at the start of every scan.
>
> **At the customer machine you run two files:** `Run-Cleanup.cmd` for the
> Windows cleanup and Defender scan, then `Scan-Clam.cmd` for the ClamAV
> scan. Nothing else needs launching.

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
7. **Browser cache gate (step 4).** The run pauses if any browser is
   running. Edge normally keeps background processes alive even with no
   window open, so expect this on nearly every machine.
   - `CLOSE` closes them for you. Open windows are asked to shut down
     first, so tabs are saved and restore on next launch; only background
     processes are force-closed.
   - **Ask the customer first if a window has unsaved work** - a
     half-written email in a browser tab is gone once it closes.
   - `SKIP` moves on and leaves browser caches alone. `Enter` re-checks if
     you would rather close them yourself.

8. **Defender passive mode (step 6).** On a machine with third-party AV
   (ESET, Norton, Avast...), Windows makes that product primary and puts
   Defender in passive mode. Defender still scans and detects, but Windows
   does not let it remediate in this mode, and there is no way to promote
   it for the duration of a scan without disabling the customer's AV -
   which we do not do. If threats are found the script asks Defender to
   remove them anyway and checks whether that worked. If it did not, the
   findings will tell you: remediate by hand and then either run a full
   scan in the customer's own AV, which CAN remove, or a Microsoft
   Defender Offline scan (checklist step 15), which runs outside Windows
   where the third-party AV is not loaded. Do not release the machine
   until one of those comes back clean.

9. Let the run go. The Defender full scan is the long step (often 1-3
   hours); the window shows elapsed time and per-step progress. Do not
   click inside the console window while it runs.
10. If the run stops with a red FATAL ERROR, photograph the screen
    (message, line number) and report it - do not just rerun and hope.

## After the automated portion

8b. **Space reclaimed and Windows.old.** The summary prints a single TOTAL
    SPACE RECLAIMED figure - that is the number the customer sees value in,
    so write it on the work order. Note that the Windows disk cleanup step
    removes **Previous Installations**, i.e. the `Windows.old` folder. That
    means the machine can no longer roll back its last Windows feature
    update. This is normally what you want on a cleanup and it frees a lot
    of space, but it is irreversible - if the customer has mentioned any
    problem that started after a recent Windows update, raise it with the
    service writer BEFORE running the cleanup.

9. **Copy the summary block onto the paper work order by hand**: machine
   name, one line per step, findings, warnings, and the verdict line.
   Nothing is saved anywhere for you - the screen is the record.
10. Read the WARNINGS section out loud to yourself. Every line there must
    be relayed to the customer (failing drive, passive-mode Defender,
    unrepaired corruption, pending reboot).

## Manual checklist (needs your judgement)

These are not printed on screen - the script ends at the summary - so work
them from this document.

11. **ClamAV**: double-click `Scan-Clam.cmd` at the stick root. It updates
    the definitions and then scans `C:\Users`, `C:\ProgramData` and
    `C:\Windows\Temp`. No setup step first - it writes a `freshclam.conf`
    if none exists, and never overwrites one that does.

    It VERIFIES the update rather than trusting it: freshclam can exit
    successfully while leaving the database a version behind. If the update
    cannot be verified it retries once with a full download, and only then
    asks you to type YES. **Read the DEFS AGE line before you type YES** - a
    CLEAN result from stale signatures is not the assurance it looks like.
    The age is on the result block for the work order.

    Skipped-file counts are normal: those are locked by running processes.
    A very large number means the scan covered less than it appears to.

    ClamAV only reports - it removes nothing. Handle every FOUND file by
    hand, then re-scan just that path:

        Scan-Clam.cmd "C:\path\to\folder"

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
