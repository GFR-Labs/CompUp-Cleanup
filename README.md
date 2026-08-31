# CompUp Bench Cleanup

PowerShell toolkit that runs on customer machines from the shop's Ventoy USB
stick as part of the $100 cleanup service. It chains the unattended
maintenance and scanning steps, then prints a summary the tech copies onto
the paper work order by hand. Nothing is saved to disk on the customer
machine except scratch files under `%TEMP%`, and nothing is ever written to
the stick during a run.

Targets: Windows 10 and Windows 11 customer machines, Windows PowerShell 5.1
(stock). No internet assumed, no modules, no installs.

## What each file does

| File | Purpose |
|------|---------|
| `Run-Cleanup.cmd` | Double-click this on the customer machine. Elevates itself (UAC prompt), bypasses execution policy, launches the cleanup, and keeps the window open no matter what. |
| `Invoke-Cleanup.ps1` | The cleanup itself: drive health gate, restore point, temp cleanup, Defender definition update + full scan, chkdsk online scan, DISM RestoreHealth, SFC. Prints the work-order summary and the manual checklist. |
| `Run-Update.cmd` | Double-click this on the BENCH machine to refresh the stick from GitHub. |
| `Update-FromGitHub.ps1` | The updater: `git pull` when git exists, otherwise downloads the repo zip and extracts it over this folder. Never touches `Tools\`. |
| `SOP-Cleanup.md` | The tech-facing procedure, step by step. Read it before your first run. |
| `.gitignore` / `.gitattributes` | Keep tool binaries and logs out of the repo; keep line endings byte-exact. |

## USB folder layout

```
X:\CompUp-Cleanup\
    Run-Cleanup.cmd          <- tech runs this on the customer machine
    Invoke-Cleanup.ps1
    Run-Update.cmd           <- tech runs this on the bench machine
    Update-FromGitHub.ps1
    README.md
    SOP-Cleanup.md
    Tools\                   <- NOT in the repo; download by hand
        ClamAV\              (clamscan.exe, freshclam.exe, db\ folder)
        Sysinternals\        (Autoruns.exe, procexp.exe)
        BleachBit\           (portable build)
```

The `Tools\` folder is gitignored. Each stick carries its own copies of the
downloaded binaries; updates from the repo will never delete or overwrite
them.

## Setting up a new stick

1. Clone this repo onto the stick (or copy an existing stick's folder and
   run the updater).
2. Create `Tools\` and download into it: ClamAV portable (run
   `freshclam.exe` once to build the `db\` folder), Sysinternals Autoruns
   and Process Explorer, BleachBit portable.
3. Test-run `Run-Cleanup.cmd` on a bench machine before first field use.

## Updating a stick

On the bench machine (internet required): double-click `Run-Update.cmd`.

- If git is installed and the folder is a clone, it does a `git pull`.
- Otherwise it downloads the repo zip from GitHub and copies it over the
  folder. Nothing is deleted, so `Tools\` and any local files survive.

ClamAV definitions are separate from repo updates: run
`Tools\ClamAV\freshclam.exe` on the bench machine to refresh them before
heading out.

## Encoding rules (do not "fix" these)

Every failure below has actually happened; the rules exist for a reason.

- All text files are **pure ASCII with CRLF line endings**. No box-drawing
  characters, no em-dashes, no smart quotes.
- `.ps1` files carry a **UTF-8 BOM**: PowerShell 5.1 reads BOM-less scripts
  as ANSI, and one stray non-ASCII byte becomes a cascade of parse errors.
- `.cmd` files carry **no BOM**: cmd.exe misreads a BOM as part of the
  first command.
- `.gitattributes` disables all git line-ending normalization (`* -text`)
  so the bytes in the repo are the bytes on the stick, via `git pull` and
  the zip download alike.

If you edit these files, keep your editor in ASCII/UTF-8-with-BOM mode and
CRLF line endings, and never paste from a word processor.

## Where the run log lives

The cleanup writes a log to the **customer machine's** `%TEMP%` (folder
name `BenchCleanup-<timestamp>`), never to the stick - a stick that drops
off the bus mid-run would otherwise kill the whole scan. The full chkdsk,
DISM, and SFC output is in that log if a result needs a second look; the
path is printed at the end of every run.
