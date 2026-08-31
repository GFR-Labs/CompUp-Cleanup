@echo off
rem =====================================================================
rem Update.cmd - one-file updater for the CompUp bench cleanup stick.
rem
rem Double-click this on the BENCH machine (it needs internet). It brings
rem the stick up to the repo's current state and leaves Tools\ alone.
rem No elevation needed: it only writes to the stick.
rem
rem WHY THIS FILE HAS TWO STAGES (the staging is not optional):
rem
rem   An update overwrites THIS VERY FILE. cmd.exe does not read a batch
rem   file into memory - it holds a handle and seeks back to a saved byte
rem   offset after each command finishes. Replace the file mid-run and cmd
rem   resumes at that stale offset, landing in the middle of whatever text
rem   now occupies it, and executes the fragment. The usual symptom is a
rem   burst of "is not recognized as an internal or external command"
rem   after an apparently successful update.
rem
rem   Stage 1 therefore copies this file to %TEMP% and re-runs it from
rem   there. Nothing overwrites the %TEMP% copy, so it can safely rewrite
rem   the stick underneath itself.
rem
rem   Stage 2 extracts the PowerShell below the payload marker at the
rem   bottom of this file into a .ps1 under %TEMP% and runs that. Writing
rem   a real file - with the UTF-8 BOM PowerShell 5.1 needs - instead of
rem   piping source into -Command means any failure reports a real line
rem   number instead of an offset into a one-line blob.
rem
rem This file must stay pure ASCII with no byte order mark: cmd.exe
rem misreads a BOM as part of the first command.
rem =====================================================================
setlocal EnableExtensions

if /i "%~1"=="/staged" goto :staged

rem ---- Stage 1: relocate to %TEMP%, then hand over. -------------------
set "STAGEDCMD=%TEMP%\CompUp-Update-staged.cmd"
copy /y "%~f0" "%STAGEDCMD%" >nul 2>&1
if errorlevel 1 (
    echo.
    echo Could not stage the updater into %TEMP%.
    echo Check that %TEMP% exists and is writable, then try again.
    echo.
    pause
    exit /b 1
)

rem The staged copy cannot work out where the stick is, so pass it. Strip
rem the trailing backslash first: "E:\CompUp-Cleanup\" ends in \" and that
rem trips quote parsing on the way through.
set "STICKDIR=%~dp0"
if "%STICKDIR:~-1%"=="\" set "STICKDIR=%STICKDIR:~0,-1%"

"%STAGEDCMD%" /staged "%STICKDIR%"
exit /b %errorlevel%

rem ---- Stage 2: running from %TEMP%; safe to rewrite the stick. -------
:staged
rem The search is for a NEWLINE followed by the marker, i.e. the marker
rem alone at the start of a line. That matters: the marker text also
rem appears on this very line, and in any comment that mentions it, and a
rem plain IndexOf would match one of those first and slice the payload out
rem of the middle of the batch section. Requiring [char]10 in front means
rem only the real marker line can match.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText('%~f0'); $i=$s.IndexOf([char]10+'#PSPAYLOAD'); if($i -lt 0){Write-Host '  Updater is corrupt: payload marker not found.' -ForegroundColor Red; exit 1}; $p=Join-Path $env:TEMP 'CompUp-Update.ps1'; [IO.File]::WriteAllText($p,$s.Substring($i+1),(New-Object Text.UTF8Encoding $true)); & $p '%~2'"

rem This pause is the last line of defence: it runs even if the payload
rem fails to parse, so the tech can read the error instead of watching the
rem window vanish.
pause
exit /b

#PSPAYLOAD
# ===========================================================================
# PowerShell payload for Update.cmd.
#
# Extracted from the .cmd into %TEMP% and run from there, so it must be told
# where the stick is - it cannot infer it from its own location. Target is
# Windows PowerShell 5.1; no modules, no PowerShell 7 syntax.
# ===========================================================================

# $TargetFolder is passed positionally by the launcher. Note there is no
# $PSScriptRoot default here: it is not reliably populated while parameter
# defaults evaluate, and it would point at %TEMP% anyway.
param([string]$TargetFolder)

Set-StrictMode -Off

$RepoOwner     = 'GFR-Labs'
$RepoName      = 'CompUp-Cleanup'
$DefaultBranch = 'main'

# A folder only counts as a cleanup stick if this file is in it. Without the
# check, a wrong argument would unpack the repo over an unrelated directory.
$Sentinel = 'Invoke-Cleanup.ps1'

function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Bad  { param([string]$m) Write-Host $m -ForegroundColor Red }

# Snapshot of file hashes, used to report what an update actually changed.
# Tools\ and .git\ are excluded: Tools\ is the tech's own binaries and .git\
# churns on every pull.
function Get-Snapshot {
    param([string]$Folder)
    $map = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($Folder.Length).TrimStart('\', '/')
        # Both separators accepted: Windows hands back '\', but a path that
        # arrived normalized must not sneak Tools\ or .git\ into the diff.
        if ($rel -match '^(Tools|\.git)(\\|/|$)') { continue }
        try {
            $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        } catch { }
    }
    return $map
}

# Encoding is the project's most expensive failure mode, so an update
# verifies it rather than trusting it. PowerShell 5.1 reads a BOM-less .ps1
# as ANSI and one non-ASCII byte becomes a cascade of parse errors; cmd.exe
# conversely misreads a BOM as part of the first command. A stray LF-only
# file means git line-ending normalization got switched back on somewhere.
# All three must fail here on the bench, not at a customer site.
function Test-FileEncoding {
    param(
        [string]$Path,
        [bool]$RequireBom
    )
    $problems = @()
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
    } catch {
        return @('could not be read')
    }

    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($RequireBom -and -not $hasBom) { $problems += 'missing UTF-8 BOM' }
    if (-not $RequireBom -and $hasBom) { $problems += 'has a UTF-8 BOM (cmd.exe cannot read it)' }

    $start = 0
    if ($hasBom) { $start = 3 }
    $bad = 0
    $loneLf = 0
    for ($i = $start; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -gt 0x7E -or ($b -lt 0x20 -and $b -ne 9 -and $b -ne 10 -and $b -ne 13)) { $bad++ }
        if ($b -eq 10 -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) { $loneLf++ }
    }
    if ($bad -gt 0)    { $problems += ('' + $bad + ' non-ASCII byte(s)') }
    if ($loneLf -gt 0) { $problems += ('' + $loneLf + ' LF line ending(s), expected CRLF') }
    return $problems
}

try {
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host '  COMPUP CLEANUP - stick updater' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ''

    # ---- Validate the target -------------------------------------------
    if (-not $TargetFolder -or -not (Test-Path -LiteralPath $TargetFolder)) {
        throw ('Stick folder not found: "' + $TargetFolder + '"')
    }
    $TargetFolder = (Resolve-Path -LiteralPath $TargetFolder).Path.TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $TargetFolder $Sentinel))) {
        throw ('"' + $TargetFolder + '" does not look like a cleanup stick (' + $Sentinel + ' is missing). Refusing to unpack the repo over it.')
    }
    Write-Host ('  Updating: ' + $TargetFolder)
    Write-Host ''

    $before = Get-Snapshot -Folder $TargetFolder
    $method = ''

    # ---- Preferred path: git pull --------------------------------------
    $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $gitCmd) { $gitCmd = Get-Command git -ErrorAction SilentlyContinue }

    if ($gitCmd -and (Test-Path -LiteralPath (Join-Path $TargetFolder '.git'))) {
        Write-Host '  git found - pulling latest...'
        # -C instead of Push-Location: the working directory of this payload
        # is %TEMP%, and -C leaves no directory state to unwind on failure.
        # --ff-only refuses to invent a merge if someone hand-edited tracked
        # files on the stick; the zip path below then takes over.
        & $gitCmd.Source -C $TargetFolder pull --ff-only origin $DefaultBranch 2>&1 |
            ForEach-Object { Write-Host ('    ' + $_) }
        if ($LASTEXITCODE -eq 0) {
            $method = 'git pull'
        } else {
            Write-Warn ('  git pull failed (exit code ' + $LASTEXITCODE + '); falling back to zip download.')
            Write-Warn '  Local edits to tracked files on the stick are the usual cause.'
            Write-Host ''
        }
    } else {
        Write-Host '  git not available (or this folder is not a clone) - using zip download.'
    }

    # ---- Fallback path: download the repo zip --------------------------
    if (-not $method) {
        # Windows 10 PowerShell 5.1 still defaults to TLS 1.0 on some builds
        # and GitHub refuses that outright; opt in to TLS 1.2 explicitly.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $zipUrl     = 'https://github.com/' + $RepoOwner + '/' + $RepoName + '/archive/refs/heads/' + $DefaultBranch + '.zip'
        # GetTempPath rather than $env:TEMP: Join-Path on a null $env:TEMP
        # fails with an opaque "cannot bind argument to parameter 'Path'"
        # that reads like a bug in this script rather than a missing
        # environment variable.
        $tempRoot   = [IO.Path]::GetTempPath()
        $zipPath    = Join-Path $tempRoot ($RepoName + '-update.zip')
        $extractDir = Join-Path $tempRoot ($RepoName + '-update-extract')

        Write-Host ('  Downloading ' + $zipUrl)
        Invoke-WebRequest -UseBasicParsing -Uri $zipUrl -OutFile $zipPath -ErrorAction Stop

        # A shop wifi captive portal answers with an HTML login page and
        # Invoke-WebRequest saves it happily. Check for the zip magic number
        # so the tech gets "not a zip" rather than a confusing extract error.
        $magic = New-Object byte[] 2
        $fs = [IO.File]::OpenRead($zipPath)
        try { $null = $fs.Read($magic, 0, 2) } finally { $fs.Close() }
        if ($magic[0] -ne 0x50 -or $magic[1] -ne 0x4B) {
            throw 'The download was not a zip file. A captive portal or proxy login page is the usual cause - open a browser, sign in to the network, then run this again.'
        }

        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop

        # The GitHub zip wraps everything in one "<repo>-<branch>" folder.
        $srcRoot = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
        if (-not $srcRoot) { throw 'The downloaded zip did not contain the expected folder.' }
        if (-not (Test-Path -LiteralPath (Join-Path $srcRoot.FullName $Sentinel))) {
            throw ('The downloaded zip is missing ' + $Sentinel + '; refusing to copy it over the stick.')
        }

        # Copy file-by-file and never delete: that is what keeps the
        # gitignored Tools\ folder of downloaded binaries intact. Tools\ is
        # skipped outright as well, in case a copy ever lands in the repo.
        $copied = 0
        foreach ($f in @(Get-ChildItem -LiteralPath $srcRoot.FullName -Recurse -File -Force)) {
            $rel = $f.FullName.Substring($srcRoot.FullName.Length + 1)
            if ($rel -match '^(Tools)(\\|/|$)') { continue }
            $dest = Join-Path $TargetFolder $rel
            $destDir = Split-Path -Parent $dest
            if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
                $null = New-Item -Path $destDir -ItemType Directory -Force
            }
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            $copied++
        }

        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        $method = 'zip download (' + $copied + ' files)'
    }

    # ---- Report what actually changed ----------------------------------
    $after = Get-Snapshot -Folder $TargetFolder
    $changed = New-Object System.Collections.ArrayList
    foreach ($k in $after.Keys) {
        if (-not $before.ContainsKey($k)) { [void]$changed.Add('added   ' + $k) }
        elseif ($before[$k] -ne $after[$k]) { [void]$changed.Add('updated ' + $k) }
    }
    foreach ($k in $before.Keys) {
        if (-not $after.ContainsKey($k)) { [void]$changed.Add('removed ' + $k) }
    }

    Write-Host ''
    Write-Host ('-' * 70)
    Write-Host ('  Method: ' + $method)
    if ($changed.Count -eq 0) {
        Write-Ok '  Already up to date - no files changed.'
    } else {
        Write-Host ('  ' + $changed.Count + ' file(s) changed:')
        foreach ($c in ($changed | Sort-Object)) { Write-Host ('    ' + $c) -ForegroundColor Cyan }
    }

    # ---- Verify the scripts are still loadable by PowerShell 5.1 -------
    Write-Host ''
    Write-Host '  Checking script encoding...'
    $encBad = $false
    $toCheck = @()
    $toCheck += @(Get-ChildItem -LiteralPath $TargetFolder -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $toCheck += @(Get-ChildItem -LiteralPath $TargetFolder -Filter '*.cmd' -File -ErrorAction SilentlyContinue)
    foreach ($file in $toCheck) {
        $needsBom = ($file.Extension -eq '.ps1')
        $probs = Test-FileEncoding -Path $file.FullName -RequireBom $needsBom
        if ($probs.Count -gt 0) {
            Write-Bad ('    ' + $file.Name + ': ' + ($probs -join ', '))
            $encBad = $true
        } else {
            if ($needsBom) { $note = 'ASCII + CRLF + BOM' } else { $note = 'ASCII + CRLF, no BOM' }
            Write-Ok ('    ' + $file.Name.PadRight(22) + $note)
        }
    }
    if ($encBad) {
        Write-Host ''
        Write-Bad '  WARNING: a file above has broken encoding and will fail on a'
        Write-Bad '  customer machine. Do not take this stick out. Re-run the'
        Write-Bad '  update; if it still fails, re-clone the folder from scratch.'
    }

    Write-Host ('-' * 70)
    Write-Host ''
    if (-not $encBad) { Write-Ok '  Stick is up to date.' }
    Write-Host ''
    Write-Host '  Tools\ binaries (ClamAV, Autoruns, Process Explorer, BleachBit)' -ForegroundColor DarkGray
    Write-Host '  are not part of the repo and were left untouched. Refresh ClamAV' -ForegroundColor DarkGray
    Write-Host '  definitions separately with Tools\ClamAV\freshclam.exe.' -ForegroundColor DarkGray
} catch {
    Write-Host ''
    Write-Bad ('  UPDATE FAILED: ' + $_.Exception.Message)
    Write-Bad ('  At line: ' + $_.InvocationInfo.ScriptLineNumber)
    Write-Host ''
    # Only offer network advice when the failure actually looks like one:
    # pinning "check your internet" onto a refused-to-copy message sends the
    # tech chasing the wrong problem.
    if ($_.Exception.Message -match 'download|resolve|connect|timed out|remote name|SSL|TLS|portal') {
        Write-Warn '  This looks like a network problem. Usual causes: no internet on'
        Write-Warn '  this machine, a captive portal not signed in to, or a firewall'
        Write-Warn '  blocking github.com.'
        Write-Host ''
    }
    Write-Warn '  Nothing was copied unless the message above says otherwise, so'
    Write-Warn '  the stick is not half-updated and re-running this is safe.'
}
