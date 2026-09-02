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

# The extracted ClamAV build sits in ClamAV\ at the stick root, beside
# Scripts\. An older layout kept it under Tools\; still honoured. Say which
# was used rather than failing with a path the tech has to guess at.
function Resolve-ClamRoot {
    if (-not $script:StickRoot) {
        throw 'ClamAV cannot be located: the host script did not set $script:StickRoot.'
    }
    # The stick folder itself, then one level up. A repo cloned into a
    # subfolder of the USB (X:\CompUp-Cleanup\) with ClamAV extracted beside
    # it at the drive root (X:\ClamAV\) is a perfectly reasonable way to
    # build a stick, and searching only the clone would miss it.
    $bases = @($script:StickRoot)
    try {
        $up = Split-Path -Parent $script:StickRoot
        if ($up) { $bases += $up }
    } catch { }
    $roots = @()
    foreach ($b in $bases) {
        $roots += (Join-Path $b 'ClamAV')
        $roots += (Join-Path (Join-Path $b 'Tools') 'ClamAV')
    }
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath (Join-Path $r 'clamscan.exe')) { return $r }
    }
    # Extracting the official zip often leaves its own folder behind, so the
    # binaries end up at ClamAV\clamav-1.4.1.win.x64\clamscan.exe rather than
    # ClamAV\clamscan.exe. Look one level down before giving up, so a stick
    # that was built by dragging the zip contents across still works.
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $sub.FullName 'clamscan.exe')) { return $sub.FullName }
        }
    }
    # Say what was actually there. "Not found" against a folder the tech can
    # see on the stick is the least useful error possible.
    $detail = ''
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) {
            $names = @(Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            if ($names.Count -eq 0) { $detail += ([Environment]::NewLine + '    ' + $r + ' exists but is empty') }
            else { $detail += ([Environment]::NewLine + '    ' + $r + ' contains: ' + (($names | Select-Object -First 8) -join ', ')) }
        } else {
            $detail += ([Environment]::NewLine + '    ' + $r + ' does not exist')
        }
    }
    throw ('ClamAV not usable: no clamscan.exe found.' + $detail + [Environment]::NewLine +
           '  Extract the portable ClamAV build so that clamscan.exe, freshclam.exe and' + [Environment]::NewLine +
           '  sigtool.exe sit directly in ' + (Join-Path $script:StickRoot 'ClamAV') + '.')
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

# ---------------------------------------------------------------------------
# File-by-file remediation of what the scan found.
#
# clamscan has --remove, but it deletes every hit with no review, and false
# positives are exactly why a human is in this loop: installers, keygens in a
# customer's own archive, game trainers and packed-but-legitimate binaries all
# trip signatures routinely. So nothing is touched without a per-file Yes.
#
# Yes QUARANTINES rather than deletes: the file is moved to a folder on the
# customer's machine and renamed so it cannot be run by accident. A tech who
# says Yes to a false positive at 5pm can put it back. A deleted file is gone,
# and "the cleanup ate my software" is a far worse call than "it is in
# quarantine, here is how to restore it".
# ---------------------------------------------------------------------------

# clamscan prints "<path>: <Signature.Name> FOUND". Windows paths contain
# colons, so the split has to be on the LAST ': ' before FOUND, not the first.
function ConvertFrom-ClamHit {
    param([string]$Line)
    if ($Line -match '^(?<path>.+):\s+(?<threat>\S+)\s+FOUND\s*$') {
        return New-Object PSObject -Property @{
            Path   = $Matches['path'].Trim()
            Threat = $Matches['threat'].Trim()
        }
    }
    return $null
}

# Evidence for the Yes/No decision. A valid Authenticode signature from a real
# publisher is the single strongest false-positive signal a tech can see.
function Get-HitEvidence {
    param([string]$Path)
    $e = New-Object PSObject -Property @{
        Exists = $false; Size = 0; Modified = $null; Signature = 'unsigned'; Hint = ''
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $e.Exists = $true
        $e.Size = [long]$item.Length
        $e.Modified = $item.LastWriteTime
    } catch {
        return $e
    }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate) {
            $subject = ('' + $sig.SignerCertificate.Subject)
            $name = $subject
            if ($subject -match 'CN=([^,]+)') { $name = $Matches[1] }
            $e.Signature = 'SIGNED, valid: ' + $name
        } elseif ($sig.Status -ne 'NotSigned') {
            $e.Signature = 'signature ' + $sig.Status
        }
    } catch { }

    $p = $Path.ToLower()
    if ($p -match '\\downloads\\')                  { $e.Hint = 'in Downloads - a common true positive' }
    elseif ($p -match '\\appdata\\local\\temp\\')   { $e.Hint = 'in Temp - usually safe to remove' }
    elseif ($p -match '\\windows\\')                { $e.Hint = 'inside Windows - be careful, check this one' }
    elseif ($p -match '\\program files')            { $e.Hint = 'inside Program Files - likely installed software' }
    return $e
}

function Invoke-ClamRemediation {
    param([string[]]$Hits)

    $result = New-Object PSObject -Property @{
        Quarantined = 0; Left = 0; Failed = 0; Gone = 0
        QuarantineDir = ''; Actions = @()
    }

    # One file can be reported under more than one signature.
    $parsed = @()
    $seen = @{}
    foreach ($h in $Hits) {
        $p = ConvertFrom-ClamHit $h
        if (-not $p) { continue }
        $key = $p.Path.ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $parsed += $p
    }
    if ($parsed.Count -eq 0) { return $result }

    $qdir = Join-Path (Join-Path $env:SystemDrive 'CompUp-Quarantine') (Get-Date -Format 'yyyyMMdd-HHmmss')
    $result.QuarantineDir = $qdir

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host ('  REMEDIATION - ' + $parsed.Count + ' file(s) to decide on') -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host '  Y quarantines the file: it is MOVED to' -ForegroundColor Gray
    Write-Host ('    ' + $qdir) -ForegroundColor Gray
    Write-Host '  and renamed so it cannot be run by accident. Nothing is deleted,' -ForegroundColor Gray
    Write-Host '  so a false positive can be put back. N leaves the file alone.' -ForegroundColor Gray

    # A big cluster of hits in one folder is usually one over-eager signature
    # rather than a machine that is truly riddled.
    if ($parsed.Count -gt 25) {
        Write-Host ''
        Write-Caution ('  ' + $parsed.Count + ' detections is a lot. Check whether they share one signature')
        Write-Caution '  name or one folder - that pattern is usually a false-positive cluster'
        Write-Caution '  rather than a genuinely riddled machine.'
    }

    $i = 0
    foreach ($p in $parsed) {
        $i++
        $ev = Get-HitEvidence $p.Path

        Write-Host ''
        Write-Host ('  ' + ('-' * 74))
        Write-Host ("  [{0} of {1}]  " -f $i, $parsed.Count) -NoNewline
        Write-Host $p.Path -ForegroundColor Yellow
        Write-Host ('    Threat   : ' + $p.Threat) -ForegroundColor Red
        if (-not $ev.Exists) {
            Write-Caution '    File is already gone (removed by another tool, or a temp file).'
            $result.Gone++
            $result.Actions += ('GONE       ' + $p.Path)
            continue
        }
        Write-Host ('    Size     : ' + (Format-Bytes $ev.Size))
        if ($ev.Modified) { Write-Host ('    Modified : ' + $ev.Modified.ToString('yyyy-MM-dd HH:mm')) }
        if ($ev.Signature -like 'SIGNED*') {
            Write-Host ('    ' + $ev.Signature) -ForegroundColor Green
            Write-Host '    A valid signature makes a false positive much more likely.' -ForegroundColor Green
        } else {
            Write-Host ('    Signature: ' + $ev.Signature)
        }
        if ($ev.Hint) { Write-Host ('    Note     : ' + $ev.Hint) }
        Write-Host ('  ' + ('-' * 74))

        $answer = ''
        while ($answer -ne 'Y' -and $answer -ne 'N') {
            $answer = ('' + (Read-Host '  Quarantine this file?  Y / N')).Trim().ToUpper()
        }
        if ($answer -eq 'N') {
            $result.Left++
            $result.Actions += ('LEFT       ' + $p.Path + '  (' + $p.Threat + ')')
            Write-Info '    Left in place.'
            continue
        }

        try {
            if (-not (Test-Path -LiteralPath $qdir)) {
                $null = New-Item -Path $qdir -ItemType Directory -Force -ErrorAction Stop
            }
            # Numbered so two files with the same name cannot collide, and
            # suffixed so a double-click in the quarantine folder does nothing.
            $leaf = Split-Path -Leaf $p.Path
            $dest = Join-Path $qdir (('{0:d3}_' -f $i) + $leaf + '.quarantined')
            Move-Item -LiteralPath $p.Path -Destination $dest -Force -ErrorAction Stop
            $result.Quarantined++
            $result.Actions += ('QUARANTINED ' + $p.Path + '  (' + $p.Threat + ')')
            Write-Good ('    Quarantined to ' + $dest)
            try {
                Add-Content -LiteralPath (Join-Path $qdir 'manifest.txt') -Encoding ASCII -ErrorAction Stop `
                    -Value (('{0:d3}' -f $i) + ' | ' + $p.Threat + ' | ' + $p.Path)
            } catch { }
        } catch {
            $result.Failed++
            $msg = ('' + $_.Exception.Message) -replace '\s+', ' '
            $result.Actions += ('FAILED     ' + $p.Path + '  (' + $msg + ')')
            Write-Alert ('    Could not move it: ' + $msg)
            Write-Alert '    Usually means it is running or locked. Note it for manual removal.'
        }
    }

    Write-Host ''
    Write-Host ('  Quarantined ' + $result.Quarantined + ', left ' + $result.Left +
                ', already gone ' + $result.Gone + ', failed ' + $result.Failed)
    if ($result.Quarantined -gt 0) {
        Write-Host ('  Quarantine folder: ' + $qdir)
        Write-Host '  To restore: rename the file back and move it to the path in manifest.txt.'
    }
    foreach ($a in $result.Actions) { Write-Log ('REMEDIATION: ' + $a) }
    return $result
}
