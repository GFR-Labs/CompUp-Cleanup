# ===========================================================================
# Scan-Clam.ps1 - ClamAV: update signatures (VERIFIED), then scan.
#
# One script, one run: update, prove the update actually landed, then scan.
# Launched by Scan-Clam.cmd, which handles elevation and execution policy.
#
# WHY THE VERIFICATION EXISTS
# freshclam exiting 0 does NOT prove it downloaded anything. It has been seen
# reporting the database a version behind and still returning success, after
# which the scan ran on stale signatures while the tech believed they were
# current. A scan believed current but is not is worse than no scan, because
# it ends the investigation.
#
# The scan half - flags, exclusions, stderr handling - is carried over from
# the shop's existing Scan-Clam.cmd, which was tuned against real machines.
# Read the exclusion note before touching those patterns.
#
# Target: Windows PowerShell 5.1. Pure ASCII, CRLF, UTF-8 BOM.
# ===========================================================================

# Optional: scan a specific path instead of the standard target set.
#   Scan-Clam.cmd "C:\Users\jane\Downloads"
# No $PSScriptRoot in this default - it is not reliably populated while
# parameter defaults evaluate. Nothing is ever assigned to $args.
param([string[]]$Target)

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Paths. Resolved after the param block, per the project rule.
# ---------------------------------------------------------------------------
$script:ScriptRoot = $null
if ($PSCommandPath) { $script:ScriptRoot = Split-Path -Parent $PSCommandPath }
if (-not $script:ScriptRoot -and $MyInvocation.MyCommand.Path) {
    $script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $script:ScriptRoot) { $script:ScriptRoot = (Get-Location).Path }

# This script lives in Scripts\; Tools\ is its sibling at the stick root.
$script:StickRoot = $null
try { $script:StickRoot = Split-Path -Parent $script:ScriptRoot } catch { }
if (-not $script:StickRoot) { $script:StickRoot = $script:ScriptRoot }

$script:RunStart = Get-Date
$script:LogPath  = $null
$script:WorkDir  = $null
$script:ClamRoot = $null
$script:DataDir  = $null
$script:ConfFile = $null
$script:ScanLog  = $null

$script:FreshclamTimeoutMinutes = 30
$script:ScanTimeoutMinutes      = 240

# ---------------------------------------------------------------------------
# Logging. Every file write is wrapped: a logging failure must never abort a
# scan. Nothing is ever written to the stick - it can drop off the bus.
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    if (-not $script:LogPath) { return }
    try {
        Add-Content -LiteralPath $script:LogPath -Encoding ASCII `
            -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message) -ErrorAction Stop
    } catch { }
}
function Write-Info    { param([string]$m) Write-Host $m;                         Write-Log $m }
function Write-Good    { param([string]$m) Write-Host $m -ForegroundColor Green;  Write-Log $m }
function Write-Caution { param([string]$m) Write-Host $m -ForegroundColor Yellow; Write-Log $m }
function Write-Alert   { param([string]$m) Write-Host $m -ForegroundColor Red;    Write-Log $m }

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) { return ('{0}h {1:d2}m' -f [int][math]::Floor($Span.TotalHours), [int]$Span.Minutes) }
    if ($Span.TotalMinutes -ge 1) { return ('{0}m {1:d2}s' -f [int]$Span.Minutes, [int]$Span.Seconds) }
    return ('{0}s' -f [int]$Span.TotalSeconds)
}

# A stray click otherwise puts the console in selection mode and freezes the
# whole scan until a key is pressed.
function Disable-QuickEdit {
    try {
        Add-Type -Namespace ClamBench -Name NativeConsole -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        $handle = [ClamBench.NativeConsole]::GetStdHandle(-10)
        $mode = [uint32]0
        if ([ClamBench.NativeConsole]::GetConsoleMode($handle, [ref]$mode)) {
            [void][ClamBench.NativeConsole]::SetConsoleMode($handle, [uint32](($mode -band 0xFFFFFFBF) -bor 0x0080))
        }
    } catch { }
}

function Initialize-WorkDir {
    try {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('ClamScan-' + $script:RunStart.ToString('yyyyMMdd-HHmmss'))
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop }
        $script:WorkDir = $dir
        $script:LogPath = Join-Path $dir 'clam-run.log'
        $script:ScanLog = Join-Path $dir 'clamscan.log'
    } catch {
        $script:WorkDir = [IO.Path]::GetTempPath()
        $script:LogPath = $null
        $script:ScanLog = Join-Path $script:WorkDir 'clamscan.log'
    }
}

# ClamAV lives in Tools\ on the stick, but a stick built by hand may have it
# straight at the root. Try both and say which was used rather than failing
# with a path the tech has to guess at.
function Resolve-ClamRoot {
    $candidates = @(
        (Join-Path (Join-Path $script:StickRoot 'Tools') 'ClamAV'),
        (Join-Path $script:StickRoot 'ClamAV')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $c 'clamscan.exe')) { return $c }
    }
    throw ('ClamAV not found. Looked for clamscan.exe in:' + [Environment]::NewLine +
           '    ' + ($candidates -join ([Environment]::NewLine + '    ')) + [Environment]::NewLine +
           '  Tools\ is not part of the repo - download the portable ClamAV build onto this stick first.')
}

# ---------------------------------------------------------------------------
# Child process with a reachable timeout.
#
# Output is polled from a redirect file, never a pipe: clamscan is extremely
# chatty and a full pipe would deadlock. The drain is bounded per pass so the
# loop always returns to the timeout check.
#
# stdout and stderr are kept SEPARATE. LibClamAV emits a warning per locked
# file on stderr, and merging them would bury the scan summary and pollute
# the FOUND-line parsing.
# ---------------------------------------------------------------------------
function Invoke-CapturedProcess {
    param(
        [string]$FilePath,
        [string]$ArgumentString,
        [int]$TimeoutMinutes,
        [string]$Activity
    )
    $token   = [Guid]::NewGuid().ToString('N')
    $outFile = Join-Path $script:WorkDir ('proc-' + $token + '-out.log')
    $errFile = Join-Path $script:WorkDir ('proc-' + $token + '-err.log')
    $result  = New-Object PSObject -Property @{
        ExitCode = $null; Output = ''; StdErr = ''; TimedOut = $false
    }

    $proc = $null
    $stream = $null
    try {
        Write-Log ('Running: ' + $FilePath + ' ' + $ArgumentString)
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentString -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $outFile); $i++) { Start-Sleep -Milliseconds 100 }
        $stream = New-Object System.IO.FileStream($outFile, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)

        $decoder = [Console]::OutputEncoding.GetDecoder()
        $byteBuf = New-Object byte[] 65536
        $charBuf = New-Object char[] 131072
        $sb = New-Object System.Text.StringBuilder
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $started = Get-Date
        $done = $false

        while (-not $done) {
            $exitedBeforeRead = $proc.HasExited
            $sawData = $false
            for ($pass = 0; $pass -lt 16; $pass++) {
                $n = $stream.Read($byteBuf, 0, $byteBuf.Length)
                if ($n -le 0) { break }
                $sawData = $true
                $nc = $decoder.GetChars($byteBuf, 0, $n, $charBuf, 0)
                [void]$sb.Append($charBuf, 0, $nc)
            }
            if ($exitedBeforeRead -and -not $sawData) {
                $done = $true
            } elseif (-not $exitedBeforeRead -and (Get-Date) -gt $deadline) {
                try { $proc.Kill() } catch { }
                $result.TimedOut = $true
                Write-Log ('TIMEOUT after ' + $TimeoutMinutes + 'm: ' + $FilePath)
                $done = $true
            } elseif (-not $sawData) {
                if ($Activity) {
                    try {
                        Write-Progress -Activity $Activity -Status (
                            'Elapsed ' + (Format-Duration ((Get-Date) - $started)) + ' (limit ' + $TimeoutMinutes + 'm)')
                    } catch { }
                }
                Start-Sleep -Milliseconds 400
            }
        }
        try { $null = $proc.WaitForExit(5000) } catch { }
        try { $result.ExitCode = $proc.ExitCode } catch { }
        $result.Output = $sb.ToString()
    } finally {
        if ($stream) { try { $stream.Close() } catch { } }
        if ($Activity) { try { Write-Progress -Activity $Activity -Completed } catch { } }
        try {
            if (Test-Path -LiteralPath $errFile) { $result.StdErr = [System.IO.File]::ReadAllText($errFile) }
        } catch { }
        try { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } catch { }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Database identity via sigtool.
#
# BOTH daily.cvd and daily.cld are checked. freshclam produces .cvd after a
# full download and .cld after incremental patching, so looking only at .cvd
# reports "cannot read the database" on a database that is perfectly fine.
# ---------------------------------------------------------------------------
function Get-DatabaseInfo {
    $info = New-Object PSObject -Property @{
        Found = $false; File = ''; Version = ''; BuildTime = $null; AgeDays = $null
    }
    $sigtool = Join-Path $script:ClamRoot 'sigtool.exe'
    if (-not (Test-Path -LiteralPath $sigtool)) {
        Write-Log 'sigtool.exe not found; cannot verify the database version.'
        return $info
    }
    foreach ($name in @('daily.cvd', 'daily.cld')) {
        $path = Join-Path $script:DataDir $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $r = Invoke-CapturedProcess -FilePath $sigtool -ArgumentString ('--info "' + $path + '"') -TimeoutMinutes 2
        $out = ('' + $r.Output + $r.StdErr)
        Write-Log ('sigtool --info ' + $name + ':' + [Environment]::NewLine + $out)
        if ($out -match '(?m)^\s*Version:\s*(\S+)') {
            $info.Found = $true; $info.File = $name; $info.Version = $Matches[1]
        }
        if ($out -match '(?m)^\s*Build time:\s*(.+?)\s*$') {
            $raw = $Matches[1]
            $dt = [datetime]::MinValue
            # sigtool prints e.g. "25 Sep 2024 08:33 -0400". Exact forms first,
            # then a loose parse, so a format change degrades to "age unknown"
            # rather than throwing.
            $parsed = $false
            foreach ($f in @('dd MMM yyyy HH:mm zzz', 'd MMM yyyy HH:mm zzz',
                             'dd MMM yyyy HH:mm:ss zzz', 'd MMM yyyy HH:mm:ss zzz')) {
                if ([datetime]::TryParseExact($raw, $f, [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::None, [ref]$dt)) { $parsed = $true; break }
            }
            if (-not $parsed) {
                $parsed = [datetime]::TryParse($raw, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref]$dt)
            }
            if ($parsed) {
                $info.BuildTime = $dt
                $info.AgeDays = [int]((Get-Date) - $dt).TotalDays
            }
        }
        if ($info.Found) { break }
    }
    return $info
}

function Format-DbInfo {
    param($Info)
    if (-not $Info.Found) { return 'unknown (sigtool could not read it)' }
    $s = $Info.File + ' v' + $Info.Version
    if ($Info.AgeDays -ne $null) { $s += ' (' + $Info.AgeDays + ' days old)' }
    return $s
}

# ---------------------------------------------------------------------------
# Did freshclam actually fail, whatever its exit code said?
#
# The matching has to be careful in BOTH directions. "Your ClamAV installation
# is OUTDATED" refers to the ENGINE binary being older than the current
# release, not to the signatures. Treating that as a failure would make every
# run stop and demand a YES, which trains techs to type YES without reading
# and destroys the value of the gate. So it is stripped before matching.
# ---------------------------------------------------------------------------
function Test-FreshclamFailed {
    param([string]$Output)
    $reasons = @()
    $text = ('' + $Output)
    $text = $text -replace '(?im)^.*your clamav installation is outdated.*$', ''
    $text = $text -replace '(?im)^.*recommended version.*$', ''
    $text = $text -replace "(?im)^.*don'?t panic.*$", ''

    $patterns = @(
        @{ Rx = '(?i)\d+\s+version[s]?\s+behind';            Why = 'database reported as versions behind' },
        @{ Rx = '(?i)database.{0,40}(out of date|outdated)'; Why = 'database reported out of date' },
        @{ Rx = "(?i)can'?t\s+download";                     Why = 'download failed' },
        @{ Rx = '(?i)failed to download';                    Why = 'download failed' },
        @{ Rx = '(?i)update failed';                         Why = 'update failed' },
        @{ Rx = '(?i)not\s+(fully\s+)?synchronized';         Why = 'mirror not synchronized' },
        @{ Rx = '(?i)^\s*ERROR[:\s]';                        Why = 'freshclam reported an error' }
    )
    foreach ($p in $patterns) { if ($text -match $p.Rx) { $reasons += $p.Why } }
    return @($reasons | Select-Object -Unique)
}

# Written only when absent, never overwritten: a conf produced by the shop's
# Setup-ClamAV.cmd may carry proxy or mirror settings this would destroy.
function New-FreshclamConfIfMissing {
    if (Test-Path -LiteralPath $script:ConfFile) { return $false }
    $lines = @(
        '# Generated by Scan-Clam because no freshclam.conf was present.',
        '# Minimal settings only. If this shop has a tuned config (proxy, private',
        '# mirror), put it here and this file will be left alone from now on.',
        'DatabaseMirror database.clamav.net',
        ('DatabaseDirectory ' + $script:DataDir),
        'Checks 24'
    )
    Set-Content -LiteralPath $script:ConfFile -Value $lines -Encoding ASCII -ErrorAction Stop
    return $true
}

function Invoke-Freshclam {
    param([string]$Activity)
    $exe = Join-Path $script:ClamRoot 'freshclam.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw ('freshclam.exe not found at ' + $exe) }
    # --datadir overrides the config so the stick's drive letter can change.
    $argStr = '--config-file="' + $script:ConfFile + '" --datadir="' + $script:DataDir + '"'
    $r = Invoke-CapturedProcess -FilePath $exe -ArgumentString $argStr `
        -TimeoutMinutes $script:FreshclamTimeoutMinutes -Activity $Activity
    Write-Log ('freshclam stdout:' + [Environment]::NewLine + $r.Output)
    Write-Log ('freshclam stderr:' + [Environment]::NewLine + $r.StdErr)
    return $r
}

# A failed or corrupt incremental .cdiff patch is the usual reason a database
# will not advance. Removing the files forces the next run to pull full .cvd
# files instead of trying to patch what is already there.
function Reset-ClamDatabase {
    $removed = 0
    foreach ($n in @('daily.cvd', 'daily.cld', 'main.cvd', 'main.cld', 'bytecode.cvd', 'bytecode.cld')) {
        $p = Join-Path $script:DataDir $n
        if (Test-Path -LiteralPath $p) {
            try {
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                $removed++
                Write-Log ('Removed ' + $n + ' to force a full download.')
            } catch {
                Write-Caution ('  Could not remove ' + $n + ': ' + $_.Exception.Message)
            }
        }
    }
    return $removed
}

# ===========================================================================
# Main
# ===========================================================================
$dbAfter = $null
$updateOk = $false
$staleAccepted = $false

try {
    Disable-QuickEdit
    Initialize-WorkDir

    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host '  CLAMAV - UPDATE (VERIFIED) THEN SCAN' -ForegroundColor Cyan
    Write-Host ('  ' + $env:COMPUTERNAME + '  |  ' + $script:RunStart.ToString('yyyy-MM-dd HH:mm'))
    Write-Host ('=' * 78) -ForegroundColor Cyan

    $script:ClamRoot = Resolve-ClamRoot
    $script:DataDir  = Join-Path $script:ClamRoot 'database'
    $script:ConfFile = Join-Path $script:ClamRoot 'freshclam.conf'
    Write-Info ('  ClamAV   : ' + $script:ClamRoot)
    Write-Info ('  Database : ' + $script:DataDir)

    if (-not (Test-Path -LiteralPath $script:DataDir)) {
        $null = New-Item -Path $script:DataDir -ItemType Directory -Force -ErrorAction SilentlyContinue
    }
    if (New-FreshclamConfIfMissing) {
        Write-Caution ('  freshclam.conf was missing; wrote a minimal one at ' + $script:ConfFile)
    }

    # ---- 1. Version BEFORE ------------------------------------------------
    Write-Host ''
    Write-Host '---- STEP 1 of 2 - Updating signatures ---------------------------------' -ForegroundColor Cyan
    $dbBefore = Get-DatabaseInfo
    Write-Info ('  Before : ' + (Format-DbInfo $dbBefore))

    # ---- 2. Update --------------------------------------------------------
    $r = Invoke-Freshclam -Activity 'freshclam (updating definitions)'
    $reasons = @(Test-FreshclamFailed ($r.Output + "`n" + $r.StdErr))
    if ($r.TimedOut) { $reasons += 'freshclam timed out' }

    # ---- 3. Version AFTER, and compare ------------------------------------
    $dbAfter = Get-DatabaseInfo
    Write-Info ('  After  : ' + (Format-DbInfo $dbAfter))
    if ($dbBefore.Version -ne $dbAfter.Version) {
        Write-Good ('  Definitions advanced: ' + $dbBefore.Version + ' -> ' + $dbAfter.Version)
    } elseif ($dbAfter.Found -and $reasons.Count -eq 0) {
        Write-Good ('  Definitions already current at v' + $dbAfter.Version)
    }

    if ($reasons.Count -eq 0 -and $dbAfter.Found) {
        $updateOk = $true
    } else {
        Write-Host ''
        Write-Caution ('  Update did NOT verify: ' + ($reasons -join '; '))
        if (-not $dbAfter.Found) { Write-Caution '  The database could not be read after the update.' }

        # ---- 4. One automatic recovery: force a full download -------------
        Write-Host ''
        Write-Caution '  Deleting the database files and retrying with a full download.'
        Write-Caution '  A broken incremental .cdiff patch is the usual cause.'
        Write-Info ('  Removed ' + (Reset-ClamDatabase) + ' database file(s).')

        $r2 = Invoke-Freshclam -Activity 'freshclam (full download retry)'
        $reasons2 = @(Test-FreshclamFailed ($r2.Output + "`n" + $r2.StdErr))
        if ($r2.TimedOut) { $reasons2 += 'freshclam timed out' }
        $dbAfter = Get-DatabaseInfo
        Write-Info ('  Retry  : ' + (Format-DbInfo $dbAfter))

        if ($reasons2.Count -eq 0 -and $dbAfter.Found) {
            $updateOk = $true
            Write-Good '  Recovery succeeded: definitions are current.'
        } else {
            # ---- 5. Still failing: the tech decides, with the age shown ---
            $ageText = 'UNKNOWN AGE'
            if ($dbAfter.AgeDays -ne $null) { $ageText = ('' + $dbAfter.AgeDays + ' DAYS OLD') }
            Write-Host ''
            Write-Alert '  ******************************************************************'
            Write-Alert '  *  DEFINITION UPDATE FAILED - SIGNATURES ARE STALE               *'
            Write-Alert '  ******************************************************************'
            Write-Alert ('  *  Database : ' + (Format-DbInfo $dbAfter))
            Write-Alert ('  *  AGE      : ' + $ageText)
            Write-Alert ('  *  Reason   : ' + ($reasons2 -join '; '))
            Write-Alert '  *'
            Write-Alert '  *  Common causes: no internet, or malware on this machine'
            Write-Alert '  *  blocking AV update servers.'
            Write-Alert '  *'
            Write-Alert '  *  A scan on stale signatures MISSES recent malware, and a CLEAN'
            Write-Alert '  *  result will read as assurance it has not earned. Fix the'
            Write-Alert '  *  update on the bench first if you possibly can.'
            Write-Alert '  ******************************************************************'
            Write-Host ''
            $answer = ''
            while ($answer -ne 'YES' -and $answer -ne 'NO') {
                $answer = ('' + (Read-Host '  Type YES to scan anyway with stale signatures, or NO to stop')).Trim().ToUpper()
            }
            if ($answer -eq 'NO') {
                Write-Host ''
                Write-Alert '  Stopped. No scan was run. Fix the definitions and try again.'
                return
            }
            $staleAccepted = $true
            Write-Log 'Tech accepted a scan on stale signatures.'
        }
    }

    # ---- 6. Scan ----------------------------------------------------------
    Write-Host ''
    Write-Host '---- STEP 2 of 2 - Scanning --------------------------------------------' -ForegroundColor Cyan
    $clamscan = Join-Path $script:ClamRoot 'clamscan.exe'
    if (-not (Test-Path -LiteralPath $clamscan)) { throw ('clamscan.exe not found at ' + $clamscan) }

    $targets = @()
    if ($Target -and $Target.Count -gt 0) {
        $targets = @($Target)
    } else {
        $targets = @(
            (Join-Path $env:SystemDrive 'Users'),
            (Join-Path $env:SystemDrive 'ProgramData'),
            (Join-Path $env:SystemRoot 'Temp')
        )
    }

    # NO $ ANCHORS in these patterns. Anchoring to end-of-string only matches
    # a path that ENDS in that name, so clamscan still descends INTO the
    # directory. The pattern must match anywhere in the path.
    #   OneDrive: Files On-Demand placeholders HYDRATE when read, so scanning
    #     them downloads the customer's entire cloud drive.
    #   All Users / Application Data / Local Settings / Documents and Settings
    #     are legacy junctions that loop back up the tree.
    #   Packages / INetCache / System Volume Information / $Recycle.Bin are
    #     high-volume noise with nothing worth scanning.
    $excludes = @(
        '(?i)\\OneDrive',
        '(?i)\\All Users',
        '(?i)\\Application Data',
        '(?i)\\Local Settings',
        '(?i)\\Documents and Settings',
        '(?i)\\System Volume Information',
        '(?i)\\\$Recycle\.Bin',
        '(?i)\\AppData\\Local\\Packages',
        '(?i)\\AppData\\Local\\Microsoft\\Windows\\INetCache'
    )

    $argParts = @(
        '-r', '-i',
        ('--database="' + $script:DataDir + '"'),
        ('--log="' + $script:ScanLog + '"'),
        '--max-filesize=100M',
        '--max-scansize=200M',
        '--max-scantime=5400000',
        '--cross-fs=no',
        '--follow-dir-symlinks=0',
        '--follow-file-symlinks=0'
    )
    foreach ($e in $excludes) { $argParts += ('--exclude-dir="' + $e + '"') }
    foreach ($t in $targets)  { $argParts += ('"' + $t + '"') }

    Write-Info ('  Targets : ' + ($targets -join ', '))
    Write-Info ('  Log     : ' + $script:ScanLog)
    Write-Host ''
    Write-Host '  Only infected files are printed. Silence means nothing found.'
    Write-Host ('  Typically 20-40 minutes; hard limit ' + $script:ScanTimeoutMinutes + ' minutes.')

    $scanStart = Get-Date
    $scan = Invoke-CapturedProcess -FilePath $clamscan -ArgumentString ($argParts -join ' ') `
        -TimeoutMinutes $script:ScanTimeoutMinutes -Activity 'clamscan'
    $scanElapsed = (Get-Date) - $scanStart
    Write-Log ('clamscan stdout:' + [Environment]::NewLine + $scan.Output)

    # ---- 7. Result block --------------------------------------------------
    $out = ('' + $scan.Output)
    $infected = $null; if ($out -match '(?m)^Infected files:\s*(\d+)') { $infected = [int]$Matches[1] }
    $scanned  = $null; if ($out -match '(?m)^Scanned files:\s*(\d+)')  { $scanned  = [int]$Matches[1] }
    $dataRead = '';    if ($out -match '(?m)^Data scanned:\s*(.+?)\s*$') { $dataRead = $Matches[1] }
    $hits = @($out -split "`r?`n" | Where-Object { $_ -match ' FOUND$' })

    # LibClamAV logs one stderr line per file it could not open. Those are
    # locked by running processes and are expected, not a failure - but the
    # count belongs on the work order, because a huge number means the scan
    # covered much less than it appears to.
    $skipped = @($scan.StdErr -split "`r?`n" | Where-Object { $_ -match "(?i)can'?t\s+(open|access|read)" }).Count

    $bar = ('=' * 78)
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host '  CLAMAV RESULT  -  copy onto the work order' -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ('  Machine  : ' + $env:COMPUTERNAME)
    Write-Host ('  Date     : ' + $script:RunStart.ToString('yyyy-MM-dd HH:mm') + '    Scan time: ' + (Format-Duration $scanElapsed))
    Write-Host ('  Database : ' + (Format-DbInfo $dbAfter))

    # The age is what says how much a CLEAN below is actually worth, so it
    # gets its own coloured line.
    Write-Host '  DEFS AGE : ' -NoNewline
    if ($dbAfter.AgeDays -eq $null) {
        Write-Host 'UNKNOWN' -ForegroundColor Yellow
    } elseif ($dbAfter.AgeDays -le 1) {
        Write-Host ($dbAfter.AgeDays.ToString() + ' day(s) - current') -ForegroundColor Green
    } elseif ($dbAfter.AgeDays -le 7) {
        Write-Host ($dbAfter.AgeDays.ToString() + ' day(s)') -ForegroundColor Yellow
    } else {
        Write-Host ($dbAfter.AgeDays.ToString() + ' DAYS - STALE') -ForegroundColor Red
    }

    Write-Host '  UPDATE   : ' -NoNewline
    if ($updateOk) { Write-Host 'verified' -ForegroundColor Green }
    else           { Write-Host 'FAILED - scanned on stale signatures' -ForegroundColor Red }

    if ($scanned -ne $null) {
        $line = '  Files    : ' + $scanned + ' scanned'
        if ($dataRead) { $line += ', ' + $dataRead }
        Write-Host $line
    }
    if ($skipped -gt 0) {
        Write-Host ('  Skipped  : ' + $skipped + ' unreadable (locked by running processes - expected)')
    }
    Write-Host ('-' * 78)

    if ($scan.TimedOut) {
        Write-Alert ('  RESULT: INCOMPLETE - hit the ' + $script:ScanTimeoutMinutes + '-minute limit')
    } elseif ($infected -ne $null -and $infected -gt 0) {
        Write-Alert ('  RESULT: ' + $infected + ' INFECTED FILE(S)')
        foreach ($h in $hits) { Write-Alert ('    ' + $h.Trim()) }
        Write-Host ''
        Write-Alert '  ClamAV does NOT remove anything. Every FOUND file must be'
        Write-Alert '  handled by hand, then re-scan that path:'
        Write-Alert '      Scan-Clam.cmd "C:\path\to\folder"'
    } elseif ($scan.ExitCode -eq 2) {
        Write-Caution '  RESULT: completed with errors - read the scan log'
    } elseif ($staleAccepted) {
        Write-Caution '  RESULT: no threats found, but ON STALE SIGNATURES - weak assurance'
    } else {
        Write-Good '  RESULT: CLEAN - no threats found'
    }
    Write-Host ('  Exit code ' + $scan.ExitCode + '   (0 clean / 1 infected / 2 error)')
    Write-Host $bar -ForegroundColor Cyan
    Write-Host '  Logs (on this machine, not the stick):' -ForegroundColor DarkGray
    Write-Host ('    ' + $script:ScanLog) -ForegroundColor DarkGray
    if ($script:LogPath) { Write-Host ('    ' + $script:LogPath) -ForegroundColor DarkGray }
} catch {
    Write-Host ''
    Write-Host ('FATAL ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('  At line  : ' + $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
    Write-Host ('  Stack    : ' + $_.ScriptStackTrace) -ForegroundColor Red
    Write-Log ('FATAL: ' + $_.Exception.Message)
} finally {
    try { Write-Progress -Activity 'clamscan' -Completed } catch { }
    Write-Host ''
    try { $null = Read-Host 'Run complete - press Enter to close this window' } catch { }
}
