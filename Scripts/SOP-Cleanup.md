# SOP: Bench Cleanup ($100 service)

Tech-facing procedure. Follow the numbers; do not skip or reorder. The
automated portion does the waiting for you - your judgement is needed at the
gate, at the summary, and in the manual checklist.

> **On the bench, before you head out:** double-click `Update.cmd` on the
> stick to pull the current version. That is the only bench step - ClamAV
> updates its own definitions at the start of every scan.
>
> **At the customer machine you run ONE file:** `Run-Cleanup.cmd`. It does
> the cleanup, the repairs, and the ClamAV scan in one pass.
>
> The Defender full scan is deliberately NOT automated - see step 11. It ran
> for one to three hours with no sign of life, so a slow scan and a hung one
> looked identical. Driven by hand from Windows Security you get a live file
> count and can tell the difference.
>
> `Scripts\Scan-Clam.cmd` exists for ONE job: re-scanning a single folder
> after you have removed something ClamAV found. It sits in `Scripts\`
> rather than the stick root precisely because it is not part of a normal
> cleanup.

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

8. **ClamAV definitions and scan (steps 5 and 6).** Step 5 runs freshclam
   and VERIFIES the update actually landed - a clean exit code is not
   enough. If it cannot be verified it asks you to type YES before
   scanning on stale signatures: **read the age it prints first**, and
   prefer fixing the update over scanning stale. Step 6 is the scan
   itself. Anything it finds is reported, never removed - see the
   remediation step below.

   If the run printed a PASSIVE warning about Defender at startup, note it
   now: it changes what you do at the manual Defender scan.

9. Let the run go. The ClamAV scan is the long step (typically 20-40
   minutes); the window shows elapsed time and per-step progress. Do not
   click inside the console window while it runs.

   **To skip a step that is clearly going nowhere** - chkdsk grinding on a
   sick drive, cleanmgr stuck on a huge Update Cleanup - press **S**, then
   type **SKIP** and Enter to confirm. Two deliberate actions, so you
   cannot do it by leaning on the keyboard. The step is marked SKIP in the
   summary and the run carries on; nothing else is lost. Pressing S and
   then Enter carries on as normal, so it is safe to check.
10. If the run stops with a red FATAL ERROR, photograph the screen
    (message, line number) and report it - do not just rerun and hope.

## After the automated portion

11. **Space reclaimed and Windows.old.** The summary prints a single TOTAL
    SPACE RECLAIMED figure - that is the number the customer sees value in,
    so write it on the work order. Note that the Windows disk cleanup step
    removes **Previous Installations**, i.e. the `Windows.old` folder. That
    means the machine can no longer roll back its last Windows feature
    update. This is normally what you want on a cleanup and it frees a lot
    of space, but it is irreversible - if the customer has mentioned any
    problem that started after a recent Windows update, raise it with the
    service writer BEFORE running the cleanup.

12. **Copy the summary block onto the paper work order by hand**: machine
   name, one line per step, findings, warnings, and the verdict line.
   Nothing is saved anywhere for you - the screen is the record.
13. Read the WARNINGS section out loud to yourself. Every line there must
    be relayed to the customer (failing drive, passive-mode Defender,
    unrepaired corruption, pending reboot).

## Manual checklist (needs your judgement)

These are not printed on screen - the script ends at the summary - so work
them from this document.

14. **Defender full scan (manual).** Windows Security > Virus and threat
    protection.

    - **If the run reported Defender as PASSIVE** (a third-party AV such as
      ESET holds primary protection), first turn on **Microsoft Defender
      Antivirus options > Periodic scanning**. Without it Defender will not
      run an on-demand scan at all. Accept the UAC prompt.
      *This is a persistent change to the customer's machine.* It is a
      reasonable one to leave on - it gives them a second engine - but note
      it on the work order either way, and turn it back off if the customer
      asks.
    - Scan options > **Full scan** > Scan now. Expect one to three hours.
      The window shows a live file count, so you can see it is alive; check
      on it rather than watching it.
    - **In passive mode Defender detects but cannot remove.** Anything it
      finds must be removed by hand, or by a full scan in the customer's
      own AV, or by a Defender Offline scan (the Defender Offline step below). Do not release the
      machine on a passive-mode detection you have not cleared.

15. **Remediate what ClamAV found** - this happens IN the run, at the very
    end, after every step has finished. If the scan found nothing you will
    never see it.

    You get one file at a time, with the evidence to judge it:

    - the full path and the threat name
    - size and last-modified date
    - **whether the file is digitally signed** - a valid signature from a
      real publisher is the strongest sign it is a false positive
    - a note on the location (Downloads is a common true positive; inside
      `Windows\` or `Program Files\` means look twice)

    Answer **Y** or **N**:

    - **Y quarantines it.** The file is MOVED to
      `C:\CompUp-Quarantine\<timestamp>\` and renamed `.quarantined` so it
      cannot be run by accident. **Nothing is deleted** - `manifest.txt` in
      that folder maps each file back to where it came from, so a false
      positive can be restored.
    - **N leaves it alone.**

    Judge them. False positives are common: installers, game trainers,
    keygens the customer downloaded themselves, and packed-but-legitimate
    software all trip signatures. If dozens of hits share one signature name
    or one folder, that is a false-positive cluster, not a riddled machine.

    A file that could not be moved is almost always running or locked -
    those are listed in the findings and still need handling by hand.

    **Re-scan afterwards to confirm**, rather than trusting the move:

          Scripts\Scan-Clam.cmd "C:\Users\name\Downloads"

    Repeat until that path comes back clean. Tell the customer their files
    are in quarantine, not deleted, and where.

16. **Autoruns** (Sysinternals; free from Microsoft, not on the stick):
    Options > Check
    VirusTotal, Hide Microsoft Entries. Review everything that remains;
    research anything you do not recognize before deleting it.
17. **Process Explorer** (Sysinternals, not on the stick): enable the
    VirusTotal column, review running processes.
18. **BleachBit** (portable build, not on the stick): browser cache and
    temp ONLY. Never
    cookies, saved passwords, or history - wiping the customer's logged-in
    sessions turns a cleanup into a callback.
19. **Defender Offline scan**: Windows Security > Virus and threat
    protection > Scan options > Microsoft Defender Antivirus (offline
    scan). The machine reboots and scans for about 15 minutes. This is the
    only step that inspects the disk while any malware is not running.
20. **Browser extensions**: review the extension list in every installed
    browser. Remove anything the customer did not choose (search
    hijackers, "coupon" toolbars) - note removals on the work order.
21. **Reboot and confirm stable**: full reboot, log in, open a browser and
    File Explorer, check that AV is active (Windows Security shows green).
    Undo any lid/power changes from step 4.

## Release

22. Verdict CLEAN and checklist clear: note "cleanup complete" and release.
23. Verdict REVIEW or ATTENTION: talk to the service writer before release.
    Threats found, unrepaired corruption, or a failing drive may mean a
    follow-up ticket or a replacement conversation - that call is not made
    at the bench.
