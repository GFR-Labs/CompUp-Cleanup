# ===========================================================================
# Update-FromGitHub.ps1 - refresh this USB stick from the GitHub repo
#
# Run this on the BENCH machine (it needs internet), not on a customer
# machine. Uses "git pull" when git is available; falls back to downloading
# the repo zip and extracting over this folder when it is not - bench
# machines are not guaranteed to have git installed.
#
# The local Tools\ folder (downloaded ClamAV, Sysinternals, BleachBit
# binaries) is gitignored, is not in the repo zip, and is never touched by
# an update.
#
# Encoding: pure ASCII, CRLF, UTF-8 BOM - same rules as Invoke-Cleanup.ps1
# (PowerShell 5.1 reads BOM-less .ps1 as ANSI). Target is Windows
# PowerShell 5.1; do not use PowerShell 7 features.
# ===========================================================================

# Deliberately no param() block (and if one is added: no $PSScriptRoot in
# defaults, no assigning to $args).

Set-StrictMode -Off

$RepoOwner     = 'GFR-Labs'
$RepoName      = 'CompUp-Cleanup'
$DefaultBranch = 'main'

# Script root, resolved after any param block would run.
$root = $null
if ($PSCommandPath) { $root = Split-Path -Parent $PSCommandPath }
if (-not $root -and $MyInvocation.MyCommand.Path) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $root) { $root = (Get-Location).Path }

try {
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host '  BENCH CLEANUP - stick updater' -ForegroundColor Cyan
    Write-Host ('  Folder: ' + $root)
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ''

    $updated = $false

    # ---- Preferred path: git pull -------------------------------------
    $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $gitCmd) { $gitCmd = Get-Command git -ErrorAction SilentlyContinue }

    if ($gitCmd -and (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        Write-Host 'git found - pulling latest...'
        Push-Location -LiteralPath $root
        try {
            # --ff-only: if someone hand-edited tracked files on the stick,
            # refuse to guess at a merge and fall back to telling the tech.
            & $gitCmd.Source pull --ff-only origin $DefaultBranch 2>&1 |
                ForEach-Object { Write-Host ('  ' + $_) }
            if ($LASTEXITCODE -eq 0) {
                $updated = $true
                Write-Host ''
                Write-Host 'Stick updated via git pull.' -ForegroundColor Green
            } else {
                Write-Host ''
                Write-Host ('git pull failed (exit code ' + $LASTEXITCODE + ').') -ForegroundColor Yellow
                Write-Host 'Local edits to tracked files on the stick can cause this.' -ForegroundColor Yellow
                Write-Host 'Falling back to zip download...' -ForegroundColor Yellow
            }
        } finally {
            Pop-Location
        }
    } else {
        Write-Host 'git not available (or this folder is not a clone) - using zip download.'
    }

    # ---- Fallback path: download the repo zip -------------------------
    if (-not $updated) {
        # Older Windows 10 PowerShell defaults to TLS 1.0 and GitHub
        # refuses the connection; opt in to TLS 1.2 explicitly.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $zipUrl     = 'https://github.com/' + $RepoOwner + '/' + $RepoName + '/archive/refs/heads/' + $DefaultBranch + '.zip'
        $zipPath    = Join-Path $env:TEMP ($RepoName + '-update.zip')
        $extractDir = Join-Path $env:TEMP ($RepoName + '-update-extract')

        Write-Host ('Downloading ' + $zipUrl + ' ...')
        Invoke-WebRequest -UseBasicParsing -Uri $zipUrl -OutFile $zipPath -ErrorAction Stop

        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop

        # The zip contains a single "<repo>-<branch>" folder at its root.
        $srcRoot = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
        if (-not $srcRoot) { throw 'Downloaded zip did not contain the expected folder.' }

        # Copy file-by-file with relative paths. Nothing is deleted, so the
        # gitignored Tools\ folder and any local logs survive; Tools\ is
        # additionally skipped outright in case a copy of it ever lands in
        # the repo.
        $copied = 0
        $srcFiles = @(Get-ChildItem -LiteralPath $srcRoot.FullName -Recurse -File -Force)
        foreach ($f in $srcFiles) {
            $rel = $f.FullName.Substring($srcRoot.FullName.Length + 1)
            if ($rel -match '^(Tools)(\\|$)') { continue }
            $dest = Join-Path $root $rel
            $destDir = Split-Path -Parent $dest
            if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
                $null = New-Item -Path $destDir -ItemType Directory -Force
            }
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            $copied++
        }

        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host ''
        Write-Host ('Stick updated from zip (' + $copied + ' files copied).') -ForegroundColor Green
        $updated = $true
    }

    Write-Host ''
    Write-Host 'Reminder: Tools\ binaries (ClamAV, Autoruns, Process Explorer,' -ForegroundColor DarkGray
    Write-Host 'BleachBit) are NOT part of the repo. Update those by hand when needed.' -ForegroundColor DarkGray
} catch {
    Write-Host ''
    Write-Host ('UPDATE FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('  At line: ' + $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
    Write-Host ''
    Write-Host 'Common causes: no internet on this machine, a firewall blocking' -ForegroundColor Yellow
    Write-Host 'github.com, or the stick is write-protected/full.' -ForegroundColor Yellow
} finally {
    Write-Host ''
    try { $null = Read-Host 'Press Enter to close this window' } catch { }
}
