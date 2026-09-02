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

The two files a tech ever double-clicks sit at the top. Everything else is
in `Scripts\`, out of the way.

| File | Purpose |
|------|---------|
| `Run-Cleanup.cmd` | Double-click this on the customer machine. Elevates itself (UAC prompt), bypasses execution policy, launches the cleanup, and keeps the window open no matter what. |
| `Update.cmd` | Double-click this on the BENCH machine to bring the stick up to the repo's current state. Self-contained: `git pull` when git exists, otherwise downloads the repo zip. Never touches `Tools\`. |
| `Scripts\Scan-Clam.cmd` | Re-scan ONE folder after removing something ClamAV found: `Scripts\Scan-Clam.cmd "C:\path"`. The normal cleanup run already includes a ClamAV scan, so this is not a standard-job file - which is why it lives in `Scripts\` and not at the root. |
| `Scripts\Invoke-Cleanup.ps1` | The cleanup itself, 11 steps: drive health gate, restore point, temp cleanup, browser caches, Defender definitions, ClamAV scan, chkdsk online scan, DISM RestoreHealth, component store cleanup, Windows disk cleanup, SFC. Prints the work-order summary and findings. The Defender FULL scan is deliberately manual - see the SOP. |
| `Scripts\Scan-Clam.ps1` | Standalone ClamAV run behind `Scripts\Scan-Clam.cmd`, for re-scanning one folder after remediation. |
| `Scripts\ClamAV.Lib.ps1` | Shared ClamAV update-and-scan logic, dot-sourced by both the cleanup script and `Scan-Clam.ps1` so they cannot drift. |
| `Scripts\SOP-Cleanup.md` | The tech-facing procedure, step by step. Read it before your first run. |
| `.gitignore` / `.gitattributes` | Keep tool binaries and logs out of the repo; keep line endings byte-exact. |

## USB folder layout

```
X:\CompUp-Cleanup\
    Run-Cleanup.cmd          <- tech runs this on the customer machine
    Update.cmd               <- tech runs this on the bench machine
    .gitattributes           <- must stay at root, see Encoding rules
    .gitignore               <- must stay at root
    Files\
        README.md
        CLAUDE.md
    Scripts\
        Invoke-Cleanup.ps1
        Scan-Clam.cmd        <- re-scan one folder after remediation
        Scan-Clam.ps1
        ClamAV.Lib.ps1
        SOP-Cleanup.md
    Tools\                   <- NOT in the repo; download by hand
        ClamAV\              (clamscan.exe, freshclam.exe, sigtool.exe,
                              database\ folder)
        Sysinternals\        (Autoruns.exe, procexp.exe)
        BleachBit\           (portable build)
```

`Tools\` is gitignored and sits at the stick root, NOT inside `Scripts\`.
Each stick carries its own copies of the downloaded binaries; updates from
the repo will never delete or overwrite them.

Both launchers are inside the repo, so `Update.cmd` updates them along with
everything else. If you ever move them outside the clone, they stop
receiving fixes entirely - `git pull` only touches files inside the clone.

Three places depend on this layout and must change together:
`Run-Cleanup.cmd` looks for `Scripts\Invoke-Cleanup.ps1` beside itself,
`Scripts\Scan-Clam.cmd` looks for `Scan-Clam.ps1` beside ITSELF (both are in
`Scripts\`), and `Update.cmd` uses the first of those as its "is this really
a cleanup stick" check.
`Scan-Clam.ps1` also resolves `Tools\ClamAV\` from one level UP, since
`Tools\` sits at the stick root.

`.gitattributes` and `.gitignore` must stay at the repo ROOT. Each only
applies from its own directory down, so a copy under `Files\` protects
`Files\` alone and leaves the root launchers and `Scripts\*.ps1` exposed to
git line-ending renormalization - which silently strips the CRLF and BOM the
scripts depend on, and un-ignores `Tools\` so a tech's binaries can be
committed.

## Setting up a new stick

1. Clone this repo onto the stick (or copy an existing stick's folder and
   run the updater).
2. Create `Tools\` and download into it: ClamAV portable, Sysinternals
   Autoruns and Process Explorer, BleachBit portable. ClamAV needs
   `clamscan.exe`, `freshclam.exe` and `sigtool.exe`; the `database\`
   folder and `freshclam.conf` are created on the first ClamAV run, so
   there is no separate setup step.
3. Test-run `Run-Cleanup.cmd` on a bench machine before first field use.

## Updating a stick

On the bench machine (internet required): double-click `Update.cmd`. That is
the whole procedure - it is one self-contained file with no companion script.

What it does:

- Refuses to run against a folder that has no `Scripts\Invoke-Cleanup.ps1`, so
  a wrong path cannot unpack the repo over some unrelated directory.
- Uses `git pull --ff-only` if git is installed and the folder is a clone.
  Falls back to downloading the repo zip otherwise, and also if the pull is
  refused (local edits to tracked files are the usual reason).
- Never deletes anything. `Tools\`, local notes, and logs all survive. The
  cost of that rule: a file removed from the repo is not removed from the
  stick by the zip path. `git pull` does remove it.
- Prints exactly which files changed, so "did that do anything?" has an
  answer.
- Verifies encoding afterwards - ASCII, CRLF, BOM on `.ps1`, no BOM on
  `.cmd` - and says loudly not to take the stick out if a file is broken.

It updates itself safely. `Update.cmd` first copies itself to `%TEMP%` and
re-runs from there, because cmd.exe reads a batch file by seeking to a saved
byte offset after each command: a batch file that overwrites itself mid-run
resumes at a stale offset and executes fragments of whatever now sits there.

ClamAV definitions are separate from repo updates, and every ClamAV scan
refreshes them itself first - so there is nothing to do on the bench for
ClamAV.

The updater tracks the repo's **`main`** branch. Work still sitting on a
feature branch will not reach a stick until it is merged.

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
