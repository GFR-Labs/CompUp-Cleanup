# ===========================================================================
# ClamAV.Lib.ps1 - shared ClamAV update-and-scan logic.
#
# Dot-sourced by BOTH Invoke-Cleanup.ps1 (which runs ClamAV as one step of
# the cleanup chain) and Scan-Clam.ps1 (which runs it standalone, for
# re-scanning a single path after remediating what the chain found). The
# logic lives here once so those two can never drift apart.
#
# The host script must already define, before dot-sourcing this:
#   $script:StickRoot                 stick root (Tools\ is under it)
#   $script:FreshclamTimeoutMinutes   update timeout
#   Invoke-CapturedProcess            with .Output .StdErr .ExitCode .TimedOut
#   Write-Log / Write-Info / Write-Good / Write-Caution / Write-Alert
#   Format-Duration
#
# and this sets $script:ClamRoot, $script:DataDir and $script:ConfFile via
# Initialize-ClamPaths.
#
# Pure ASCII, CRLF, UTF-8 BOM - same rules as every other .ps1 here.
# ===========================================================================

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Paths. Kept out of Resolve-ClamRoot so a host can report the location
# before deciding whether ClamAV is usable at all.
# ---------------------------------------------------------------------------
function Initialize-ClamPaths {
    $script:ClamRoot = Resolve-ClamRoot
    $script:DataDir  = Join-Path $script:ClamRoot 'database'
    $script:ConfFile = Join-Path $script:ClamRoot 'freshclam.conf'
    if (-not (Test-Path -LiteralPath $script:DataDir)) {
        $null = New-Item -Path $script:DataDir -ItemType Directory -Force -ErrorAction SilentlyContinue
    }
}

# True when this stick actually carries ClamAV. Lets a host skip the step
# cleanly rather than throwing on a machine whose stick was built without it.
function Test-ClamAvailable {
    try {
        $null = Resolve-ClamRoot
        return $true
    } catch {
        return $false
    }
}

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
# ---------------------------------------------------------------------------
# The whole verified-update flow, in one place.
#
# Returns: Ok (update verified), StaleAccepted (tech chose to scan anyway),
# Aborted (tech chose to stop), Db (database info after), Reasons (why it
# failed). A host renders that however it likes.
#
# $Interactive controls only the final gate. Inside the cleanup chain the
# tech is present and answering prompts anyway, so it stays $true there too;
# it exists so an unattended caller cannot be left blocked on Read-Host.
# ---------------------------------------------------------------------------
function Invoke-ClamUpdateVerified {
    param([bool]$Interactive = $true)

    $result = New-Object PSObject -Property @{
        Ok = $false; StaleAccepted = $false; Aborted = $false
        Db = $null; Reasons = @(); Advanced = $false
    }

    if (New-FreshclamConfIfMissing) {
        Write-Caution ('  freshclam.conf was missing; wrote a minimal one at ' + $script:ConfFile)
    }

    $dbBefore = Get-DatabaseInfo
    Write-Info ('  Before : ' + (Format-DbInfo $dbBefore))

    $r = Invoke-Freshclam -Activity 'freshclam (updating definitions)'
    $reasons = @(Test-FreshclamFailed ($r.Output + "`n" + $r.StdErr))
    if ($r.TimedOut) { $reasons += 'freshclam timed out' }

    $dbAfter = Get-DatabaseInfo
    Write-Info ('  After  : ' + (Format-DbInfo $dbAfter))
    if ($dbBefore.Version -ne $dbAfter.Version) {
        $result.Advanced = $true
        Write-Good ('  Definitions advanced: ' + $dbBefore.Version + ' -> ' + $dbAfter.Version)
    } elseif ($dbAfter.Found -and $reasons.Count -eq 0) {
        Write-Good ('  Definitions already current at v' + $dbAfter.Version)
    }

    if ($reasons.Count -eq 0 -and $dbAfter.Found) {
        $result.Ok = $true
        $result.Db = $dbAfter
        return $result
    }

    Write-Host ''
    Write-Caution ('  Update did NOT verify: ' + ($reasons -join '; '))
    if (-not $dbAfter.Found) { Write-Caution '  The database could not be read after the update.' }

    # One automatic recovery. A broken incremental .cdiff patch is the usual
    # reason a database will not advance, and deleting the files forces a
    # full download instead of another attempt to patch what is there.
    Write-Host ''
    Write-Caution '  Deleting the database files and retrying with a full download.'
    Write-Info ('  Removed ' + (Reset-ClamDatabase) + ' database file(s).')

    $r2 = Invoke-Freshclam -Activity 'freshclam (full download retry)'
    $reasons2 = @(Test-FreshclamFailed ($r2.Output + "`n" + $r2.StdErr))
    if ($r2.TimedOut) { $reasons2 += 'freshclam timed out' }
    $dbAfter = Get-DatabaseInfo
    Write-Info ('  Retry  : ' + (Format-DbInfo $dbAfter))
    $result.Db = $dbAfter
    $result.Reasons = $reasons2

    if ($reasons2.Count -eq 0 -and $dbAfter.Found) {
        $result.Ok = $true
        Write-Good '  Recovery succeeded: definitions are current.'
        return $result
    }

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
    Write-Alert '  *  result will read as assurance it has not earned.'
    Write-Alert '  ******************************************************************'
    Write-Host ''

    if (-not $Interactive) {
        $result.Aborted = $true
        return $result
    }
    $answer = ''
    while ($answer -ne 'YES' -and $answer -ne 'NO') {
        $answer = ('' + (Read-Host '  Type YES to scan anyway with stale signatures, or NO to skip the scan')).Trim().ToUpper()
    }
    if ($answer -eq 'NO') {
        $result.Aborted = $true
    } else {
        $result.StaleAccepted = $true
        Write-Log 'Tech accepted a scan on stale signatures.'
    }
    return $result
}

# ---------------------------------------------------------------------------
# The scan itself, with the shop's tuned flag and exclusion set.
# ---------------------------------------------------------------------------
function Invoke-ClamScan {
    param(
        [string[]]$Targets,
        [string]$ScanLogPath,
        [int]$TimeoutMinutes
    )
    $clamscan = Join-Path $script:ClamRoot 'clamscan.exe'
    if (-not (Test-Path -LiteralPath $clamscan)) { throw ('clamscan.exe not found at ' + $clamscan) }

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
        ('--log="' + $ScanLogPath + '"'),
        '--max-filesize=100M',
        '--max-scansize=200M',
        '--max-scantime=5400000',
        '--cross-fs=no',
        '--follow-dir-symlinks=0',
        '--follow-file-symlinks=0'
    )
    foreach ($e in $excludes) { $argParts += ('--exclude-dir="' + $e + '"') }
    foreach ($t in $Targets)  { $argParts += ('"' + $t + '"') }

    $started = Get-Date
    $scan = Invoke-CapturedProcess -FilePath $clamscan -ArgumentString ($argParts -join ' ') `
        -TimeoutMinutes $TimeoutMinutes -Activity 'clamscan'
    Write-Log ('clamscan stdout:' + [Environment]::NewLine + $scan.Output)

    $out = ('' + $scan.Output)
    $res = New-Object PSObject -Property @{
        Infected = $null; Scanned = $null; DataRead = ''; Hits = @()
        Skipped = 0; TimedOut = $scan.TimedOut; ExitCode = $scan.ExitCode
        Elapsed = ((Get-Date) - $started)
    }
    if ($out -match '(?m)^Infected files:\s*(\d+)')  { $res.Infected = [int]$Matches[1] }
    if ($out -match '(?m)^Scanned files:\s*(\d+)')   { $res.Scanned  = [int]$Matches[1] }
    if ($out -match '(?m)^Data scanned:\s*(.+?)\s*$'){ $res.DataRead = $Matches[1] }
    $res.Hits = @($out -split "`r?`n" | Where-Object { $_ -match ' FOUND$' })
    # LibClamAV logs one stderr line per file it could not open. Those are
    # locked by running processes and expected - but the count matters,
    # because a huge number means the scan covered less than it appears to.
    $res.Skipped = @($scan.StdErr -split "`r?`n" | Where-Object { $_ -match "(?i)can'?t\s+(open|access|read)" }).Count
    return $res
}
