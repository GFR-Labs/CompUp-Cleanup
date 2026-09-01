# ===========================================================================
# Scan-Clam.ps1 - ClamAV definition update (verified) then on-demand scan
#
# One script: update, PROVE the update landed, then scan. Launch it with
# Scan-Clam.cmd, which handles elevation and execution policy.
#
# Why the verification exists: freshclam exiting 0 does NOT prove it
# downloaded anything. It has been seen reporting the database a version
# behind and returning success, after which the scan ran on stale signatures
# while the tech believed they were current. A scan believed to be current
# but is not is worse than no scan at all, because it ends the investigation.
#
# Target: Windows PowerShell 5.1. Pure ASCII, CRLF, UTF-8 BOM.
# ===========================================================================

# No param() block. If one is ever added: never use $PSScriptRoot in a
# parameter default (not reliably populated while defaults evaluate) and
# never assign to $args.

Set-StrictMode -Off

# Script root, resolved after any param block would have run.
$script:ScriptRoot = $null
if ($PSCommandPath) { $script:ScriptRoot = Split-Path -Parent $PSCommandPath }
if (-not $script:ScriptRoot -and $MyInvocation.MyCommand.Path) {
    $script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $script:ScriptRoot) { $script:ScriptRoot = (Get-Location).Path }

# Tools\ sits beside Scripts\ at the stick root, not inside it.
$script:StickRoot = $null
try { $script:StickRoot = Split-Path -Parent $script:ScriptRoot } catch { }
if (-not $script:StickRoot) { $script:StickRoot = $script:ScriptRoot }

$script:ClamRoot   = Join-Path (Join-Path $script:StickRoot 'Tools') 'ClamAV'
$script:DataDir    = Join-Path $script:ClamRoot 'db'
$script:ConfigFile = Join-Path $script:ClamRoot 'freshclam.conf'
$script:RunStart   = Get-Date
$script:LogPath    = $null
$script:WorkDir    = $null

$script:FreshclamTimeoutMinutes = 30
$script:ScanTimeoutMinutes      = 240

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
    } catch {
        $script:WorkDir = [IO.Path]::GetTempPath()
        $script:LogPath = $null
    }
}

# ---------------------------------------------------------------------------
# Runs a child process, capturing output, with a reachable timeout.
# Output is polled from a redirect file rather than a pipe: clamscan is very
# chatty and a full pipe would deadlock. The drain is bounded per pass so the
# loop always returns to the timeout check.
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
    $result  = New-Object PSObject -Property @{ ExitCode = $null; Output = ''; TimedOut = $false }

    $proc = $null
    $stream = $null
    try {
        Write-Log ('Running: ' + $FilePath + ' ' + $ArgumentString)
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentString -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $outFile); $i++) { Start-Sleep -Milliseconds 100 }
        $stream = New-Object System.IO.FileStream($outFile, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)

        $enc = [Console]::OutputEncoding
        $decoder = $enc.GetDecoder()
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
                        Write-Progress -Activity $Activity `
                            -Status ('Elapsed ' + (Format-Duration ((Get-Date) - $started)) + ' (limit ' + $TimeoutMinutes + 'm)')
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
            if (Test-Path -LiteralPath $errFile) {
                $result.Output += [System.IO.File]::ReadAllText($errFile)
            }
        } catch { }
        try { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } catch { }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Database identity, read with sigtool.
#
# freshclam produces daily.cvd or daily.cld depending on whether the last
# update was a full download or an incremental patch, so BOTH are checked.
# ---------------------------------------------------------------------------
function Get-DatabaseInfo {
    $info = New-Object PSObject -Property @{
        Found     = $false
        File      = ''
        Version   = ''
        BuildTime = $null
        AgeDays   = $null
    }
    $sigtool = Join-Path $script:ClamRoot 'sigtool.exe'
    if (-not (Test-Path -LiteralPath $sigtool)) {
        Write-Log 'sigtool.exe not found; cannot verify the database.'
        return $info
    }
    foreach ($name in @('daily.cvd', 'daily.cld')) {
        $path = Join-Path $script:DataDir $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $r = Invoke-CapturedProcess -FilePath $sigtool `
            -ArgumentString ('--info "' + $path + '"') -TimeoutMinutes 2
        $out = ('' + $r.Output)
        Write-Log ('sigtool --info ' + $name + ':' + [Environment]::NewLine + $out)
        if ($out -match '(?m)^\s*Version:\s*(\S+)') {
            $info.Found   = $true
            $info.File    = $name
            $info.Version = $Matches[1]
        }
        if ($out -match '(?m)^\s*Build time:\s*(.+?)\s*$') {
            $raw = $Matches[1]
            $dt = [datetime]::MinValue
            # sigtool prints e.g. "25 Sep 2024 08:33 -0400". Try the exact
            # forms first, then fall back, so a format change degrades to
            # "age unknown" instead of throwing.
            $formats = @('dd MMM yyyy HH:mm zzz', 'd MMM yyyy HH:mm zzz',
                         'dd MMM yyyy HH:mm:ss zzz', 'd MMM yyyy HH:mm:ss zzz')
            $parsed = $false
            foreach ($f in $formats) {
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
# Does freshclam's output say the database is behind or that it failed?
#
# The exit code is not trustworthy here, which is the whole reason this
# script exists. But the matching has to be careful in the other direction
# too: "Your ClamAV installation is OUTDATED" refers to the ENGINE binary
# being older than the current release, not the signatures. Treating that as
# a failure would make every single run stop and demand a YES, which trains
# techs to type YES without reading - defeating the point.
# ---------------------------------------------------------------------------
function Test-FreshclamFailed {
    param([string]$Output)
    $reasons = @()
    $text = ('' + $Output)

    # Strip the engine-version warning before looking for trouble, so its
    # wording cannot trip the database patterns below.
    $text = $text -replace '(?im)^.*your clamav installation is outdated.*$', ''
    $text = $text -replace '(?im)^.*recommended version.*$', ''
    $text = $text -replace '(?im)^.*dON.T PANIC.*$', ''

    $patterns = @(
        @{ Rx = '(?i)\d+\s+version[s]?\s+behind';         Why = 'database reported as versions behind' },
        @{ Rx = '(?i)database.{0,40}(out of date|outdated)'; Why = 'database reported out of date' },
        @{ Rx = "(?i)can'?t\s+download";                  Why = 'download failed' },
        @{ Rx = '(?i)failed to download';                 Why = 'download failed' },
        @{ Rx = '(?i)update failed';                      Why = 'update failed' },
        @{ Rx = '(?i)not synchronized';                   Why = 'mirror not synchronized' },
        @{ Rx = '(?i)^\s*ERROR[:\s]';                     Why = 'freshclam reported an error' },
        @{ Rx = '(?i)mirrors are not fully synchronized'; Why = 'mirror not synchronized' }
    )
    foreach ($p in $patterns) {
        if ($text -match $p.Rx) { $reasons += $p.Why }
    }
    return @($reasons | Select-Object -Unique)
}

function Invoke-Freshclam {
    param([string]$Activity)
    $exe = Join-Path $script:ClamRoot 'freshclam.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw ('freshclam.exe not found at ' + $exe) }
    $argStr = '--config-file="' + $script:ConfigFile + '" --datadir="' + $script:DataDir + '"'
    $r = Invoke-CapturedProcess -FilePath $exe -ArgumentString $argStr `
        -TimeoutMinutes $script:FreshclamTimeoutMinutes -Activity $Activity
    Write-Log ('freshclam output:' + [Environment]::NewLine + $r.Output)
    return $r
}

# A failed or corrupt incremental .cdiff patch is the usual reason a database
# will not advance. Removing the database files forces the next run to pull a
# full .cvd instead of trying to patch what is there.
function Reset-ClamDatabase {
    $names = @('daily.cvd', 'daily.cld', 'main.cvd', 'main.cld', 'bytecode.cvd', 'bytecode.cld')
    $removed = 0
    foreach ($n in $names) {
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
$dbBefore = $null
$dbAfter  = $null
$updateOk = $false
$scanResult = $null
$staleAccepted = $false

try {
    Disable-QuickEdit
    Initialize-WorkDir

    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host '  CLAMAV UPDATE + SCAN' -ForegroundColor Cyan
    Write-Host ('  ' + $env:COMPUTERNAME + '  |  ' + $script:RunStart.ToString('yyyy-MM-dd HH:mm'))
    Write-Host ('=' * 78) -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $script:ClamRoot)) {
        throw ('ClamAV not found at ' + $script:ClamRoot + '. Tools\ is not part of the repo; download the portable build onto this stick first.')
    }
    if (-not (Test-Path -LiteralPath $script:DataDir)) {
        $null = New-Item -Path $script:DataDir -ItemType Directory -Force -ErrorAction SilentlyContinue
    }

    # ---- 1. Database identity BEFORE the update --------------------------
    Write-Host ''
    Write-Host '---- Definition update -------------------------------------------------' -ForegroundColor Cyan
    $dbBefore = Get-DatabaseInfo
    Write-Info ('  Before update: ' + (Format-DbInfo $dbBefore))

    # ---- 2. Update -------------------------------------------------------
    $r = Invoke-Freshclam -Activity 'freshclam (updating definitions)'
    $reasons = Test-FreshclamFailed $r.Output
    if ($r.TimedOut) { $reasons += 'freshclam timed out' }

    # ---- 3. Database identity AFTER ---------------------------------------
    $dbAfter = Get-DatabaseInfo
    Write-Info ('  After update:  ' + (Format-DbInfo $dbAfter))

    $changed = ($dbBefore.Version -ne $dbAfter.Version)
    if ($changed) {
        Write-Good ('  Definitions advanced: ' + $dbBefore.Version + ' -> ' + $dbAfter.Version)
    } elseif ($dbAfter.Found -and $reasons.Count -eq 0) {
        Write-Good ('  Definitions already current at v' + $dbAfter.Version)
    }

    # A clean exit code is not enough: freshclam has returned 0 while
    # reporting the database a version behind.
    if ($reasons.Count -eq 0 -and $dbAfter.Found) {
        $updateOk = $true
    } else {
        Write-Host ''
        Write-Caution ('  Update did NOT verify: ' + (($reasons | Select-Object -Unique) -join '; '))
        if (-not $dbAfter.Found) { Write-Caution '  The database could not be read after the update.' }

        # ---- 4. One automatic recovery: force a full download ------------
        Write-Host ''
        Write-Caution '  Removing the database files and retrying with a full download.'
        Write-Caution '  A broken incremental .cdiff patch is the usual cause.'
        $removed = Reset-ClamDatabase
        Write-Info ('  Removed ' + $removed + ' database file(s).')

        $r2 = Invoke-Freshclam -Activity 'freshclam (full download retry)'
        $reasons2 = Test-FreshclamFailed $r2.Output
        if ($r2.TimedOut) { $reasons2 += 'freshclam timed out' }
        $dbAfter = Get-DatabaseInfo
        Write-Info ('  After retry:   ' + (Format-DbInfo $dbAfter))

        if ($reasons2.Count -eq 0 -and $dbAfter.Found) {
            $updateOk = $true
            Write-Good '  Recovery succeeded: definitions are current.'
        } else {
            # ---- 5. Still failing: the tech decides --------------------
            $ageText = 'unknown age'
            if ($dbAfter.AgeDays -ne $null) { $ageText = ('' + $dbAfter.AgeDays + ' DAYS OLD') }
            Write-Host ''
            Write-Alert '  ******************************************************************'
            Write-Alert '  *  DEFINITION UPDATE FAILED - SIGNATURES ARE STALE               *'
            Write-Alert '  ******************************************************************'
            Write-Alert ('  *  Database: ' + (Format-DbInfo $dbAfter))
            Write-Alert ('  *  AGE: ' + $ageText)
            Write-Alert ('  *  Reason: ' + (($reasons2 | Select-Object -Unique) -join '; '))
            Write-Alert '  *'
            Write-Alert '  *  A scan with stale signatures will MISS recent malware, and a'
            Write-Alert '  *  CLEAN result will read as assurance it has not earned.'
            Write-Alert '  *  Fix the update on the bench before scanning if you can.'
            Write-Alert '  ******************************************************************'
            Write-Host ''
            $answer = ''
            while ($answer -ne 'YES' -and $answer -ne 'NO') {
                $answer = ('' + (Read-Host '  Type YES to scan anyway with stale signatures, or NO to stop')).Trim().ToUpper()
            }
            if ($answer -eq 'NO') {
                Write-Host ''
                Write-Alert '  Stopped. No scan was run. Update the definitions and try again.'
                return
            }
            $staleAccepted = $true
            Write-Log 'Tech accepted a scan on stale signatures.'
        }
    }

    # ---- 6. Scan ---------------------------------------------------------
    Write-Host ''
    Write-Host '---- Scan --------------------------------------------------------------' -ForegroundColor Cyan
    $clamscan = Join-Path $script:ClamRoot 'clamscan.exe'
    if (-not (Test-Path -LiteralPath $clamscan)) { throw ('clamscan.exe not found at ' + $clamscan) }

    $targets = @(
        (Join-Path $env:SystemDrive 'Users'),
        (Join-Path $env:SystemDrive 'ProgramData'),
        (Join-Path $env:SystemRoot 'Temp')
    )
    # OneDrive is excluded because Files On-Demand placeholders hydrate when
    # scanned, which downloads the customer's entire cloud drive. The rest are
    # the legacy compatibility junctions, which loop forever under -r.
    $excludes = @(
        '(?i).*[\\/]OneDrive.*',
        '(?i).*[\\/]Application Data([\\/].*)?$',
        '(?i).*[\\/]Local Settings([\\/].*)?$',
        '(?i).*[\\/]All Users([\\/].*)?$',
        '(?i).*[\\/]Documents and Settings([\\/].*)?$'
    )
    $argParts = @('-r', '-i', ('--database="' + $script:DataDir + '"'))
    foreach ($e in $excludes) { $argParts += ('--exclude-dir="' + $e + '"') }
    foreach ($t in $targets) { $argParts += ('"' + $t + '"') }

    Write-Info ('  Targets: ' + ($targets -join ', '))
    Write-Info '  Excluding OneDrive and the legacy junctions.'
    Write-Info ('  This is the long step; limit ' + $script:ScanTimeoutMinutes + ' minutes.')

    $scanStart = Get-Date
    $scanResult = Invoke-CapturedProcess -FilePath $clamscan -ArgumentString ($argParts -join ' ') `
        -TimeoutMinutes $script:ScanTimeoutMinutes -Activity 'clamscan'
    $scanElapsed = (Get-Date) - $scanStart
    Write-Log ('clamscan output:' + [Environment]::NewLine + $scanResult.Output)

    # ---- 7. Result block --------------------------------------------------
    $out = ('' + $scanResult.Output)
    $infected = $null
    if ($out -match '(?m)^Infected files:\s*(\d+)') { $infected = [int]$Matches[1] }
    $scanned = $null
    if ($out -match '(?m)^Scanned files:\s*(\d+)') { $scanned = [int]$Matches[1] }
    $hits = @($out -split "`r?`n" | Where-Object { $_ -match ' FOUND$' })

    $bar = ('=' * 78)
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host '  CLAMAV RESULT  -  copy onto the work order' -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ('  Machine   : ' + $env:COMPUTERNAME)
    Write-Host ('  Date      : ' + $script:RunStart.ToString('yyyy-MM-dd HH:mm') + '    Scan time: ' + (Format-Duration $scanElapsed))
    Write-Host ('  Database  : ' + (Format-DbInfo $dbAfter))

    # The age is the number that says how much the CLEAN below is worth, so
    # it gets its own coloured line rather than sitting inside the line above.
    $ageLine = '  DEFS AGE  : '
    if ($dbAfter.AgeDays -eq $null) {
        Write-Host $ageLine -NoNewline; Write-Host 'UNKNOWN' -ForegroundColor Yellow
    } elseif ($dbAfter.AgeDays -le 1) {
        Write-Host $ageLine -NoNewline; Write-Host ($dbAfter.AgeDays.ToString() + ' day(s) - current') -ForegroundColor Green
    } elseif ($dbAfter.AgeDays -le 7) {
        Write-Host $ageLine -NoNewline; Write-Host ($dbAfter.AgeDays.ToString() + ' day(s)') -ForegroundColor Yellow
    } else {
        Write-Host $ageLine -NoNewline; Write-Host ($dbAfter.AgeDays.ToString() + ' DAYS - STALE') -ForegroundColor Red
    }

    Write-Host ('  Update    : ' + $(if ($updateOk) { 'verified' } else { 'FAILED - scanned on stale signatures' })) `
        -ForegroundColor $(if ($updateOk) { 'Green' } else { 'Red' })
    if ($scanned -ne $null) { Write-Host ('  Files     : ' + $scanned + ' scanned') }
    Write-Host ('-' * 78)

    if ($scanResult.TimedOut) {
        Write-Alert ('  RESULT: INCOMPLETE - scan hit the ' + $script:ScanTimeoutMinutes + '-minute limit')
    } elseif ($infected -ne $null -and $infected -gt 0) {
        Write-Alert ('  RESULT: ' + $infected + ' INFECTED FILE(S)')
        foreach ($h in $hits) { Write-Alert ('    ' + $h.Trim()) }
        Write-Host ''
        Write-Alert '  ClamAV only REPORTS here - nothing was removed or quarantined.'
        Write-Alert '  Remediate by hand and re-scan.'
    } elseif ($scanResult.ExitCode -eq 2) {
        Write-Caution '  RESULT: completed with errors - see the run log'
    } elseif ($staleAccepted) {
        Write-Caution '  RESULT: no threats found, but ON STALE SIGNATURES - weak assurance'
    } else {
        Write-Good '  RESULT: CLEAN - no threats found'
    }
    Write-Host $bar -ForegroundColor Cyan
    if ($script:LogPath) {
        Write-Host '  Full run log (on this machine, not the stick):' -ForegroundColor DarkGray
        Write-Host ('    ' + $script:LogPath) -ForegroundColor DarkGray
    }
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
