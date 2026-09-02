# ===========================================================================
# Invoke-Cleanup.ps1 - Bench Cleanup Runner
#
# Runs the unattended maintenance chain on a customer machine, then prints a
# summary block the tech copies onto the paper work order by hand. Display
# only: NOTHING is written to the USB stick, because the stick can drop off
# the bus mid-run and invalidate open file handles. All scratch files and the
# run log live under %TEMP%.
#
# Target: Windows PowerShell 5.1 on stock Windows 10/11. Do not use anything
# newer - PowerShell 7 is not on customer machines. No modules, no internet
# assumed, no external dependencies.
#
# Encoding: this file must stay pure ASCII with CRLF line endings and a
# UTF-8 BOM. PowerShell 5.1 reads BOM-less .ps1 files as ANSI, and a single
# non-ASCII byte produces a cascade of parse errors on some codepages.
#
# Launch via Run-Cleanup.cmd, which handles elevation and execution policy.
# ===========================================================================

# Deliberately no param() block. If one is ever added: never use
# $PSScriptRoot in a parameter default (not reliably populated while
# defaults evaluate) and never assign to $args (automatic variable,
# behaves inconsistently under [CmdletBinding()]).

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Script root - resolved here, after any param block would have run.
# Fallback chain: $PSCommandPath -> $MyInvocation -> current directory.
# ---------------------------------------------------------------------------
$script:ScriptRoot = $null
if ($PSCommandPath) {
    $script:ScriptRoot = Split-Path -Parent $PSCommandPath
}
if (-not $script:ScriptRoot -and $MyInvocation.MyCommand.Path) {
    $script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $script:ScriptRoot) {
    $script:ScriptRoot = (Get-Location).Path
}

# ---------------------------------------------------------------------------
# Run-wide state
# ---------------------------------------------------------------------------
$script:RunStart          = Get-Date
$script:WorkDir           = $null   # under %TEMP%; set in Initialize-WorkDir
$script:LogPath           = $null
$script:StepResults       = New-Object System.Collections.ArrayList
$script:Findings          = New-Object System.Collections.ArrayList
$script:CustomerWarnings  = New-Object System.Collections.ArrayList
$script:AbortRun          = $false  # set when the tech types STOP at the drive gate
$script:DefenderAvailable = $false
$script:WindowsText       = 'Windows (version unknown)'
$script:TotalReclaimed    = [long]0   # headline number for the work order

# Resolved once: %SystemDrive% is not guaranteed to be C: on every machine.
$script:SystemDriveLetter = $env:SystemDrive
if (-not $script:SystemDriveLetter) { $script:SystemDriveLetter = 'C:' }

# Timeouts. Every one of these is enforced by a loop that is guaranteed to
# come back around (see Invoke-CapturedProcess / Invoke-JobWithTimeout).
$script:SigUpdateTimeoutMinutes = 15
$script:ChkdskTimeoutMinutes    = 90
$script:DismTimeoutMinutes      = 180
$script:SfcTimeoutMinutes       = 120
$script:ComponentCleanupTimeoutMinutes = 120
$script:CleanMgrTimeoutMinutes         = 90
# Shorter than Scripts\Scan-Clam.cmd's standalone 240: in the chain a stuck scan
# holds up every step behind it, and 20-40 minutes is the normal range.
$script:ClamScanTimeoutMinutes         = 120
$script:FreshclamTimeoutMinutes        = 30

$script:TotalSteps = 11

# ---------------------------------------------------------------------------
# Logging and console helpers.
# Every file write is wrapped in try/catch: a logging failure must never
# abort a scan.
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    if (-not $script:LogPath) { return }
    try {
        Add-Content -LiteralPath $script:LogPath -Encoding ASCII `
            -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message) `
            -ErrorAction Stop
    } catch { }
}

function Write-Info    { param([string]$Message) Write-Host $Message;                          Write-Log $Message }
function Write-Good    { param([string]$Message) Write-Host $Message -ForegroundColor Green;   Write-Log $Message }
function Write-Caution { param([string]$Message) Write-Host $Message -ForegroundColor Yellow;  Write-Log $Message }
function Write-Alert   { param([string]$Message) Write-Host $Message -ForegroundColor Red;     Write-Log $Message }

function Add-Finding {
    param([string]$Text)
    [void]$script:Findings.Add($Text)
    Write-Log ("FINDING: " + $Text)
}

function Add-CustomerWarning {
    param([string]$Text)
    [void]$script:CustomerWarnings.Add($Text)
    Write-Log ("CUSTOMER WARNING: " + $Text)
}

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) {
        return ('{0}h {1:d2}m' -f [int][math]::Floor($Span.TotalHours), [int]$Span.Minutes)
    }
    if ($Span.TotalMinutes -ge 1) {
        return ('{0}m {1:d2}s' -f [int]$Span.Minutes, [int]$Span.Seconds)
    }
    return ('{0}s' -f [int]$Span.TotalSeconds)
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:n2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:n1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:n0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

# Wraps one long finding to the summary block width with a hanging indent.
# The tech copies this block onto paper by hand, so a ragged console wrap in
# the middle of a threat name is worse than a slightly shorter line.
function Write-Wrapped {
    param(
        [string]$Text,
        [string]$FirstPrefix,
        [string]$ContinuePrefix,
        [int]$Width,
        [string]$Color
    )
    $line = $FirstPrefix
    $onLine = $false
    foreach ($word in ($Text -split '\s+')) {
        if (-not $word) { continue }
        if ($onLine) { $candidate = $line + ' ' + $word } else { $candidate = $line + $word }
        # A single over-long word (usually a file path) is left to overflow:
        # breaking a path mid-token makes it useless to read.
        if ($onLine -and $candidate.Length -gt $Width) {
            Write-Host $line -ForegroundColor $Color
            $line = $ContinuePrefix + $word
        } else {
            $line = $candidate
        }
        $onLine = $true
    }
    if ($onLine) { Write-Host $line -ForegroundColor $Color }
}

# ---------------------------------------------------------------------------
# Space reclaimed. The total is the headline number on the work order - it is
# what the customer sees value in - so it is accumulated across every step
# that frees anything.
#
# Two kinds of measurement feed it: byte counts of files actually deleted
# (temp, browser caches), and free-space deltas on C: (DISM, cleanmgr) where
# the tooling does the deleting and will not tell us how much it removed.
# ---------------------------------------------------------------------------
function Add-Reclaimed {
    param([long]$Bytes)
    if ($Bytes -gt 0) { $script:TotalReclaimed += $Bytes }
}

function Get-FreeSpaceBytes {
    try {
        $d = Get-PSDrive -Name $script:SystemDriveLetter.TrimEnd(':') -ErrorAction Stop
        return [long]$d.Free
    } catch {
        return [long]0
    }
}

# A free-space delta is noisy: anything else running on the machine writes to
# C: while a step runs, so the delta can come back negative even though the
# step reclaimed space. Report the real delta, but never let a negative one
# subtract from the headline total.
function Add-ReclaimedFromFreeSpace {
    param([long]$Before, [long]$After)
    $delta = $After - $Before
    if ($delta -gt 0) {
        Add-Reclaimed $delta
        return $delta
    }
    Write-Log ('Free-space delta was ' + $delta + ' bytes; not counted toward the total.')
    return [long]0
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'OK'     { return 'Green' }
        'REVIEW' { return 'Yellow' }
        'SKIP'   { return 'DarkGray' }
        'FAIL'   { return 'Red' }
        'THREAT' { return 'Red' }
        default  { return 'Gray' }
    }
}

# ---------------------------------------------------------------------------
# Console QuickEdit. A stray click in the console window otherwise switches
# it to selection mode and silently freezes the whole run until a key is
# pressed - this has eaten hours of bench time before.
# ---------------------------------------------------------------------------
function Disable-QuickEdit {
    try {
        Add-Type -Namespace BenchCleanup -Name NativeConsole -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        $handle = [BenchCleanup.NativeConsole]::GetStdHandle(-10)  # STD_INPUT_HANDLE
        $mode = [uint32]0
        if ([BenchCleanup.NativeConsole]::GetConsoleMode($handle, [ref]$mode)) {
            # Clear ENABLE_QUICK_EDIT_MODE (0x0040); ENABLE_EXTENDED_FLAGS
            # (0x0080) must be set or the QuickEdit bit is ignored.
            $newMode = [uint32](($mode -band 0xFFFFFFBF) -bor 0x0080)
            [void][BenchCleanup.NativeConsole]::SetConsoleMode($handle, $newMode)
        }
    } catch {
        # Non-console host or locked-down machine; run continues without it.
    }
}

function Test-IsAdmin {
    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Initialize-WorkDir {
    # Scratch area under %TEMP%, never the stick. Step 3 wipes %TEMP% but
    # excludes this folder so we do not delete our own log mid-run.
    try {
        $dir = Join-Path $env:TEMP ('BenchCleanup-' + $script:RunStart.ToString('yyyyMMdd-HHmmss'))
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop
        }
        $script:WorkDir = $dir
        $script:LogPath = Join-Path $dir 'cleanup-run.log'
        Write-Log ('Run started. ScriptRoot=' + $script:ScriptRoot)
    } catch {
        # No scratch dir means no log and no captured process output files,
        # but the run itself still proceeds.
        $script:WorkDir = $env:TEMP
        $script:LogPath = $null
    }
}

function Get-WindowsVersionText {
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $name  = [string]$cv.ProductName
        $build = 0
        try { $build = [int]$cv.CurrentBuildNumber } catch { }
        # ProductName still says "Windows 10" on Windows 11; build number is
        # the reliable discriminator (22000+ is 11).
        if ($build -ge 22000 -and $name -match 'Windows 10') {
            $name = ($name -replace 'Windows 10', 'Windows 11')
        }
        $release = [string]$cv.DisplayVersion
        if (-not $release) { $release = [string]$cv.ReleaseId }
        return ('{0} {1} (build {2})' -f $name, $release, $build).Trim()
    } catch {
        return 'Windows (version unknown)'
    }
}

function Get-SystemExePath {
    param([string]$ExeName)
    # From a 32-bit PowerShell on 64-bit Windows, System32 silently redirects
    # to SysWOW64 where sfc/dism behave differently or are missing; Sysnative
    # escapes the redirect. The .cmd launcher starts a 64-bit PowerShell, so
    # this is belt-and-braces.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $candidate = Join-Path (Join-Path $env:SystemRoot 'Sysnative') $ExeName
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return Join-Path (Join-Path $env:SystemRoot 'System32') $ExeName
}

function Test-PendingReboot {
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
        $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($sm -and $sm.PendingFileRenameOperations) { return $true }
    } catch { }
    return $false
}

# ---------------------------------------------------------------------------
# External process runner with a reachable timeout.
#
# The child's stdout/stderr are redirected to files under %TEMP% and polled,
# so there is no pipe for a chatty tool to fill and no blocking read to hang
# on. Both CR and LF are treated as line terminators because DISM redraws
# its progress bar with bare carriage returns - a newline-only reader blocks
# forever on it. SFC writes UTF-16 to stdout, so callers pass the encoding.
# ---------------------------------------------------------------------------
function Invoke-CapturedProcess {
    param(
        [string]$FilePath,
        [string]$ArgumentString,
        [int]$TimeoutMinutes,
        [System.Text.Encoding]$ReaderEncoding,
        [string]$Activity
    )
    if (-not $ReaderEncoding) { $ReaderEncoding = [Console]::OutputEncoding }
    $token   = [Guid]::NewGuid().ToString('N')
    $outFile = Join-Path $script:WorkDir ('proc-' + $token + '-out.log')
    $errFile = Join-Path $script:WorkDir ('proc-' + $token + '-err.log')

    $result = New-Object PSObject -Property @{
        ExitCode = $null
        Output   = ''
        StdErr   = ''
        TimedOut = $false
    }

    $proc = $null
    $stream = $null
    try {
        Write-Log ('Running: ' + $FilePath + ' ' + $ArgumentString + ' (timeout ' + $TimeoutMinutes + 'm)')
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentString `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        # The redirect file appears almost immediately; wait briefly for it.
        for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $outFile); $i++) {
            Start-Sleep -Milliseconds 100
        }
        $stream = New-Object System.IO.FileStream($outFile,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)

        $decoder = $ReaderEncoding.GetDecoder()   # handles multi-byte chars split across reads
        $byteBuf = New-Object byte[] 65536
        $charBuf = New-Object char[] 131072
        $textSb  = New-Object System.Text.StringBuilder
        $lineSb  = New-Object System.Text.StringBuilder
        $CR = [char]13
        $LF = [char]10
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $procStart = Get-Date
        $sawPercent = $false   # cleanmgr prints nothing; fall back to elapsed
        $done = $false

        while (-not $done) {
            $exitedBeforeRead = $proc.HasExited
            $sawData = $false
            # Bounded drain: at most 16 x 64 KB per pass, so even the
            # chattiest tool cannot starve the timeout check below.
            for ($pass = 0; $pass -lt 16; $pass++) {
                $n = $stream.Read($byteBuf, 0, $byteBuf.Length)
                if ($n -le 0) { break }
                $sawData = $true
                $nc = $decoder.GetChars($byteBuf, 0, $n, $charBuf, 0)
                for ($ci = 0; $ci -lt $nc; $ci++) {
                    $ch = $charBuf[$ci]
                    [void]$textSb.Append($ch)
                    if ($ch -eq $CR -or $ch -eq $LF) {
                        if ($lineSb.Length -gt 0) {
                            $line = $lineSb.ToString()
                            [void]$lineSb.Remove(0, $lineSb.Length)
                            if ($Activity -and $line -match '(\d{1,3}(?:\.\d+)?)\s*%') {
                                $sawPercent = $true
                                $pct = [int][math]::Min(100, [math]::Max(0, [double]$Matches[1]))
                                Write-Progress -Id 2 -ParentId 1 -Activity $Activity `
                                    -Status $line.Trim() -PercentComplete $pct
                            }
                        }
                    } else {
                        [void]$lineSb.Append($ch)
                    }
                }
            }
            if ($exitedBeforeRead -and -not $sawData) {
                # Exited and the file is fully drained.
                $done = $true
            } elseif (-not $exitedBeforeRead -and (Get-Date) -gt $deadline) {
                try { $proc.Kill() } catch { }
                $result.TimedOut = $true
                Write-Log ('TIMEOUT after ' + $TimeoutMinutes + 'm: ' + $FilePath)
                $done = $true
            } elseif (-not $sawData) {
                # A process that prints no progress at all (cleanmgr) would
                # otherwise look identical to a hung one. Show elapsed time
                # against the limit so the tech knows it is still alive.
                if ($Activity -and -not $sawPercent) {
                    try {
                        Write-Progress -Id 2 -ParentId 1 -Activity $Activity `
                            -Status ('Elapsed ' + (Format-Duration ((Get-Date) - $procStart)) +
                                     ' (limit ' + $TimeoutMinutes + 'm)')
                    } catch { }
                }
                Start-Sleep -Milliseconds 400
            }
        }

        try { $null = $proc.WaitForExit(5000) } catch { }
        try { $result.ExitCode = $proc.ExitCode } catch { }
        $result.Output = $textSb.ToString() + $lineSb.ToString()
    } finally {
        if ($stream) { try { $stream.Close() } catch { } }
        if ($Activity) {
            try { Write-Progress -Id 2 -ParentId 1 -Activity $Activity -Completed } catch { }
        }
        try {
            if (Test-Path -LiteralPath $errFile) {
                $result.StdErr = [System.IO.File]::ReadAllText($errFile, $ReaderEncoding)
            }
        } catch { }
        try { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } catch { }
    }
    Write-Log ('Exit code: ' + $result.ExitCode + '  TimedOut: ' + $result.TimedOut)
    return $result
}

# ---------------------------------------------------------------------------
# Runs a scriptblock in a background job with an elapsed-time heartbeat and a
# hard timeout. Used for the Defender cmdlets, which block with no progress
# output and, offline, can otherwise sit forever.
# ---------------------------------------------------------------------------
function Invoke-JobWithTimeout {
    param(
        [scriptblock]$Body,
        [int]$TimeoutMinutes,
        [string]$Activity
    )
    $outcome = @{ TimedOut = $false; Errors = @() }
    $job = Start-Job -ScriptBlock $Body
    $started = Get-Date
    try {
        while ($job.State -eq 'Running') {
            $elapsed = (Get-Date) - $started
            if ($elapsed.TotalMinutes -gt $TimeoutMinutes) {
                try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { }
                $outcome.TimedOut = $true
                Write-Log ('TIMEOUT after ' + $TimeoutMinutes + 'm: ' + $Activity)
                break
            }
            try {
                Write-Progress -Id 2 -ParentId 1 -Activity $Activity `
                    -Status ('Elapsed ' + (Format-Duration $elapsed) + ' (limit ' + $TimeoutMinutes + 'm)')
            } catch { }
            Start-Sleep -Seconds 5
        }
        $jobErrors = @()
        $null = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors
        $outcome.Errors = @($jobErrors)
    } finally {
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
        try { Write-Progress -Id 2 -ParentId 1 -Activity $Activity -Completed } catch { }
    }
    return $outcome
}

# ---------------------------------------------------------------------------
# Step 1: Drive health gate
# ---------------------------------------------------------------------------
function Step-DriveHealth {
    $problems = New-Object System.Collections.ArrayList
    $diskCount = 0
    $notes = ''

    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
        $diskCount = $disks.Count
        foreach ($d in $disks) {
            $health = ('' + $d.HealthStatus)
            $oper   = ('' + $d.OperationalStatus)
            Write-Info ('  Disk: ' + $d.FriendlyName + '  [' + $d.MediaType + ']  Health=' + $health + '  Status=' + $oper)
            if ($health -and $health -ne 'Healthy') {
                [void]$problems.Add(('Disk "' + $d.FriendlyName + '" reports HealthStatus ' + $health))
            }
            if ($oper -and $oper -ne 'OK') {
                [void]$problems.Add(('Disk "' + $d.FriendlyName + '" reports OperationalStatus ' + $oper))
            }
        }
    } catch {
        $notes = 'Get-PhysicalDisk unavailable; '
        Write-Caution ('  Get-PhysicalDisk failed: ' + $_.Exception.Message)
    }

    # SMART failure prediction. Frequently unavailable for NVMe or drives
    # behind RAID/Intel RST controllers - that is not itself a failure.
    $smartChecked = $false
    try {
        $smart = @(Get-CimInstance -Namespace 'root\wmi' `
            -ClassName 'MSStorageDriver_FailurePredictStatus' -ErrorAction Stop)
        $smartChecked = $true
        foreach ($s in $smart) {
            if ($s.PredictFailure) {
                [void]$problems.Add(('SMART predicts FAILURE on "' + $s.InstanceName + '"'))
            }
        }
    } catch {
        $notes += 'SMART predict data not readable (common on NVMe/RAID)'
        Write-Caution '  SMART failure prediction not readable (common on NVMe/RAID).'
    }

    if ($problems.Count -eq 0) {
        $detail = ('' + $diskCount + ' disk(s) healthy')
        if ($smartChecked) { $detail += ', SMART clean' }
        if ($notes) { $detail += ' - ' + $notes.Trim().TrimEnd(';') }
        return @{ Status = 'OK'; Detail = $detail }
    }

    # --- GATE ---
    Write-Host ''
    Write-Alert '  ********************************************************************'
    Write-Alert '  *  DRIVE HEALTH WARNING - STOP                                     *'
    Write-Alert '  ********************************************************************'
    foreach ($p in $problems) { Write-Alert ('  *  ' + $p) }
    Write-Alert '  *'
    Write-Alert '  *  A drive that is failing means this ticket should become a DRIVE'
    Write-Alert '  *  REPLACEMENT conversation with the customer BEFORE burning bench'
    Write-Alert '  *  hours on cleanup. Talk to the service writer now.'
    Write-Alert '  ********************************************************************'
    Write-Host ''

    Add-CustomerWarning ('Drive health problem: ' + ($problems -join '; ') + '. Recommend drive replacement / backup immediately.')
    Add-Finding ('Drive health gate tripped: ' + ($problems -join '; '))

    $answer = ''
    while ($answer -ne 'CONTINUE' -and $answer -ne 'STOP') {
        $answer = ('' + (Read-Host '  Type CONTINUE to run cleanup anyway, or STOP to end the run')).Trim().ToUpper()
    }
    if ($answer -eq 'STOP') {
        $script:AbortRun = $true
        return @{ Status = 'FAIL'; Detail = ($problems -join '; ') + ' - run stopped by tech' }
    }
    Write-Log 'Tech typed CONTINUE past the drive health gate.'
    return @{ Status = 'FAIL'; Detail = ($problems -join '; ') + ' - tech chose to continue' }
}

# ---------------------------------------------------------------------------
# Step 2: Restore point
# ---------------------------------------------------------------------------
function Step-RestorePoint {
    if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) {
        return @{ Status = 'REVIEW'; Detail = 'Checkpoint-Computer not available on this system' }
    }
    $warnText = @()
    try {
        Checkpoint-Computer -Description 'Pre-Cleanup' -RestorePointType 'MODIFY_SETTINGS' `
            -WarningVariable warnText -WarningAction SilentlyContinue -ErrorAction Stop
    } catch {
        $msg = ('' + $_.Exception.Message) -replace '\s+', ' '
        Add-Finding ('Restore point could not be created: ' + $msg + ' (System Restore may be disabled - do not change it without asking).')
        return @{ Status = 'REVIEW'; Detail = 'Failed: ' + $msg }
    }
    # Windows silently refuses a second restore point within 24h and only
    # emits a warning, so success without checking the warning is a lie.
    $joined = ('' + ($warnText -join ' '))
    if ($joined -match 'already been created|cannot be created') {
        Write-Log ('Checkpoint-Computer warning: ' + $joined)
        return @{ Status = 'REVIEW'; Detail = 'Skipped: one exists from last 24h' }
    }
    return @{ Status = 'OK'; Detail = 'Created "Pre-Cleanup"' }
}

# ---------------------------------------------------------------------------
# Step 3: Temp cleanup
# ---------------------------------------------------------------------------
function Clear-TempFolder {
    param(
        [string]$Path,
        [string[]]$ExcludePrefixes
    )
    $stat = @{ Bytes = [long]0; Files = 0; Locked = 0 }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $stat }

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $skip = $false
        foreach ($ex in $ExcludePrefixes) {
            if ($ex -and $f.FullName.StartsWith($ex, [System.StringComparison]::OrdinalIgnoreCase)) {
                $skip = $true
                break
            }
        }
        if ($skip) { continue }
        $len = [long]$f.Length
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $stat.Bytes += $len
            $stat.Files++
        } catch {
            # In use or access denied - normal for temp folders, move on.
            $stat.Locked++
        }
    }

    # Sweep now-empty directories, deepest first. Non-empty or locked ones
    # simply stay (Remove-Item without -Recurse refuses non-empty dirs).
    $dirs = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue) |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($d in $dirs) {
        $skip = $false
        foreach ($ex in $ExcludePrefixes) {
            if (-not $ex) { continue }
            if ($d.FullName.StartsWith($ex, [System.StringComparison]::OrdinalIgnoreCase) -or
                $ex.StartsWith($d.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $skip = $true
                break
            }
        }
        if ($skip) { continue }
        try { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop } catch { }
    }
    return $stat
}

function Step-TempCleanup {
    # Our own scratch dir lives under %TEMP% and must survive this step.
    $exclude = @($script:WorkDir)
    $targets = @(
        $env:TEMP,
        (Join-Path $env:SystemRoot 'Temp'),
        (Join-Path $env:SystemRoot 'Prefetch')
    )
    $totalBytes = [long]0
    $totalFiles = 0
    $totalLocked = 0
    foreach ($t in $targets) {
        Write-Info ('  Cleaning ' + $t + ' ...')
        $s = Clear-TempFolder -Path $t -ExcludePrefixes $exclude
        $totalBytes += $s.Bytes
        $totalFiles += $s.Files
        $totalLocked += $s.Locked
    }

    # Recycle bin. Size it first via the shell so "bytes freed" is honest.
    $binBytes = [long]0
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(10)   # ssfBITBUCKET
        if ($bin) {
            foreach ($item in @($bin.Items())) {
                try { $binBytes += [long]$item.Size } catch { }
            }
        }
    } catch { }
    $binNote = 'recycle bin skipped'
    try {
        if (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue) {
            Clear-RecycleBin -Force -ErrorAction Stop
            $totalBytes += $binBytes
            $binNote = 'recycle bin emptied (' + (Format-Bytes $binBytes) + ')'
        }
    } catch {
        # Some builds throw a COM error when the bin is already empty.
        if ($binBytes -eq 0) {
            $binNote = 'recycle bin already empty'
        } else {
            $binNote = 'recycle bin could not be emptied'
        }
    }

    # Headline number only on the work order; the in-use count and recycle
    # bin state go to the log, where a second look would go looking for them.
    Add-Reclaimed $totalBytes
    Write-Log ('Temp cleanup: ' + $totalLocked + ' file(s) in use and skipped; ' + $binNote)
    return @{ Status = 'OK'; Detail = ('Freed ' + (Format-Bytes $totalBytes) + ' (' + $totalFiles + ' files)') }
}

# ---------------------------------------------------------------------------
# Step 4: Defender definition update
# ---------------------------------------------------------------------------
# Reads how Defender is configured, so the summary can tell the tech what to
# expect from the manual scan. READ ONLY - PUA protection and the passive/
# active decision are the customer's configuration and are never changed.
function Get-DefenderPosture {
    $out = @{ Status = 'OK'; Suffix = '' }
    if (-not $script:DefenderAvailable) { return $out }

    $thirdParty = @()
    try {
        foreach ($av in @(Get-CimInstance -Namespace 'root\SecurityCenter2' `
                -ClassName 'AntiVirusProduct' -ErrorAction Stop)) {
            if (('' + $av.displayName) -notmatch 'Windows Defender|Microsoft Defender') {
                $thirdParty += ('' + $av.displayName)
            }
        }
    } catch { }

    $mode = ''
    try { $mode = ('' + (Get-MpComputerStatus -ErrorAction Stop).AMRunningMode) } catch { }
    if ($mode) { Write-Info ('  Defender running mode: ' + $mode) }

    # PUA state changes what a manual scan will and will not flag.
    try {
        $pua = [int](Get-MpPreference -ErrorAction Stop).PUAProtection
        if ($pua -eq 0) {
            Write-Caution '  PUA protection is OFF on this machine.'
            Add-Finding 'PUA protection is off, so the manual Defender scan will not flag potentially unwanted applications. Do not change the setting; note it for the customer.'
        }
    } catch { }

    if ($thirdParty.Count -gt 0) {
        $names = ($thirdParty -join ' / ')
        Write-Caution ('  Third-party AV present: ' + $names)
        Add-Finding ('Third-party AV installed: ' + $names)
    }

    if ($mode -match 'Passive') {
        $names = 'a third-party AV'
        if ($thirdParty.Count -gt 0) { $names = ($thirdParty -join ' / ') }
        Write-Caution '  Defender is PASSIVE. For the manual full scan you must first turn on'
        Write-Caution '  Windows Security > Virus and threat protection > Microsoft Defender'
        Write-Caution '  Antivirus options > Periodic scanning.'
        Add-Finding ('Defender is in passive mode because ' + $names + ' holds primary protection. Turn on Periodic scanning in Windows Security before the manual full scan, or Defender will not scan on demand. Remember Defender cannot remediate in passive mode: remove anything it finds by hand, or use a Defender Offline scan.')
        $out.Status = 'REVIEW'
        $out.Suffix = ' - PASSIVE'
    }
    return $out
}

# Kept even though the Defender SCAN is now manual: it takes about a minute
# and means the tech's manual full scan starts with current signatures
# instead of downloading them first while they wait.
function Step-DefinitionUpdate {
    if (-not $script:DefenderAvailable) {
        return @{ Status = 'REVIEW'; Detail = 'Defender cmdlets not available on this machine' }
    }
    $before = ''
    $beforeDate = $null
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        $before = ('' + $st.AntivirusSignatureVersion)
        $beforeDate = $st.AntivirusSignatureLastUpdated
    } catch { }

    # Run in a job: with no internet Update-MpSignature can stall well past
    # its own patience, and this bench has no guaranteed connection.
    $r = Invoke-JobWithTimeout -Body { Update-MpSignature -ErrorAction Stop } `
        -TimeoutMinutes $script:SigUpdateTimeoutMinutes -Activity 'Updating Defender definitions'

    $after = $before
    $afterDate = $beforeDate
    try {
        $st2 = Get-MpComputerStatus -ErrorAction Stop
        $after = ('' + $st2.AntivirusSignatureVersion)
        $afterDate = $st2.AntivirusSignatureLastUpdated
    } catch { }

    $ageNote = ''
    if ($afterDate) {
        $ageDays = [int]((Get-Date) - $afterDate).TotalDays
        $ageNote = ' (' + $afterDate.ToString('yyyy-MM-dd') + ')'
        if ($ageDays -gt 7) {
            Add-Finding ('Defender definitions are ' + $ageDays + ' days old; the scan ran with stale signatures.')
        }
    }

    if ($r.TimedOut) {
        return @{ Status = 'REVIEW'; Detail = 'Timed out; using ' + $after + $ageNote }
    }
    if ($r.Errors.Count -gt 0) {
        Write-Log ('Update-MpSignature error: ' + ('' + $r.Errors[0]))
        return @{ Status = 'REVIEW'; Detail = 'No update (offline?); using ' + $after + $ageNote }
    }
    # Posture for the MANUAL scan that follows. Read-only: nothing here
    # changes the customer's configuration. This used to live in the
    # automated scan step; it matters more now, because the tech is about to
    # drive Defender by hand and needs to know what they are walking into.
    $posture = Get-DefenderPosture

    if ($after -ne $before) {
        return @{ Status = $posture.Status; Detail = $before + ' -> ' + $after + $posture.Suffix }
    }
    return @{ Status = $posture.Status; Detail = 'Current: ' + $after + $ageNote + $posture.Suffix }
}

# ---------------------------------------------------------------------------
# ClamAV: update the signatures, verify the update landed, then scan.
#
# This replaced the automated Defender full scan, which took one to three
# hours and gave no sign of life while it ran, so a slow scan and a hung one
# looked identical. Defender is now a manual step in the SOP, where Windows
# Security shows real progress. ClamAV runs here instead: it is a second
# opinion from a different engine, it prints per-file output so it visibly
# progresses, and it is unaffected by whether Defender is passive.
#
# The scan runs AFTER the temp and browser cleanup steps deliberately - there
# is no point scanning files that are about to be deleted, and on a neglected
# machine that removes a lot of scan surface.
# ---------------------------------------------------------------------------
function Step-ClamScan {
    if (-not (Test-ClamAvailable)) {
        Add-Finding 'ClamAV is not on this stick (Tools\ClamAV\clamscan.exe missing), so the second-opinion scan did not run. Rebuild the stick before the next job.'
        return @{ Status = 'REVIEW'; Detail = 'ClamAV not on this stick - skipped' }
    }
    Initialize-ClamPaths
    Write-Info ('  Database: ' + $script:DataDir)

    $upd = Invoke-ClamUpdateVerified -Interactive $true
    $db = $upd.Db
    $ageText = 'age unknown'
    if ($db -and $db.AgeDays -ne $null) { $ageText = ('' + $db.AgeDays + 'd old') }

    if ($upd.Aborted) {
        Add-Finding 'ClamAV definitions could not be updated and the tech declined to scan on stale signatures, so no ClamAV scan was run.'
        Add-CustomerWarning 'The second-opinion virus scan did not run because its definitions could not be updated.'
        return @{ Status = 'SKIP'; Detail = 'Update failed, scan declined' }
    }
    if ($upd.StaleAccepted) {
        Add-Finding ('ClamAV scanned on STALE signatures (' + $ageText + '): the update could not be verified. A clean result here is weak assurance.')
    }

    $targets = @(
        (Join-Path $env:SystemDrive 'Users'),
        (Join-Path $env:SystemDrive 'ProgramData'),
        (Join-Path $env:SystemRoot 'Temp')
    )
    $scanLog = Join-Path $script:WorkDir 'clamscan.log'
    Write-Info ('  Scanning ' + ($targets -join ', '))
    Write-Info ('  Only infected files are printed; limit ' + $script:ClamScanTimeoutMinutes + ' minutes.')

    $scan = Invoke-ClamScan -Targets $targets -ScanLogPath $scanLog `
        -TimeoutMinutes $script:ClamScanTimeoutMinutes

    if ($scan.Skipped -gt 0) {
        Write-Log ('clamscan skipped ' + $scan.Skipped + ' unreadable file(s) - locked by running processes.')
    }
    if ($scan.TimedOut) {
        Add-Finding ('ClamAV scan hit the ' + $script:ClamScanTimeoutMinutes + '-minute limit and was stopped; the result is incomplete.')
        return @{ Status = 'FAIL'; Detail = 'Timed out - INCOMPLETE' }
    }
    if ($scan.Infected -ne $null -and $scan.Infected -gt 0) {
        foreach ($h in $scan.Hits) { Add-Finding ('ClamAV FOUND: ' + $h.Trim()) }
        Add-Finding 'ClamAV only reports - it removed nothing. Handle each FOUND file by hand, then re-scan that path with: Scripts\Scan-Clam.cmd "C:\path\to\folder"'
        Add-CustomerWarning ('A second-opinion scan found ' + $scan.Infected + ' infected file(s). These were NOT removed automatically and need manual remediation.')
        return @{ Status = 'THREAT'; Detail = ('' + $scan.Infected + ' infected - see findings') }
    }
    if ($scan.ExitCode -eq 2) {
        Add-Finding 'ClamAV completed with errors; the scan log is in the run folder.'
        return @{ Status = 'REVIEW'; Detail = 'Completed with errors' }
    }
    if ($upd.StaleAccepted) {
        return @{ Status = 'REVIEW'; Detail = ('Clean but STALE defs (' + $ageText + ')') }
    }
    return @{ Status = 'OK'; Detail = ('Clean, defs ' + $ageText) }
}

# ---------------------------------------------------------------------------
# Step 6: Disk check (online scan - no reboot, never /f or /r)
# ---------------------------------------------------------------------------
function Step-DiskCheck {
    $sysDrive = $env:SystemDrive
    if (-not $sysDrive) { $sysDrive = 'C:' }
    # /scan is the online variant. /f or /r would schedule a reboot-time
    # check on the customer's machine - never add them here.
    $r = Invoke-CapturedProcess -FilePath (Get-SystemExePath 'chkdsk.exe') `
        -ArgumentString ($sysDrive + ' /scan') `
        -TimeoutMinutes $script:ChkdskTimeoutMinutes `
        -Activity ('chkdsk ' + $sysDrive + ' /scan')

    Write-Log ('chkdsk output follows:' + [Environment]::NewLine + $r.Output)

    if ($r.TimedOut) {
        return @{ Status = 'FAIL'; Detail = 'Timed out after ' + $script:ChkdskTimeoutMinutes + 'm' }
    }
    $out = ('' + $r.Output)
    if ($out -match 'found no problems') {
        return @{ Status = 'OK'; Detail = 'File system clean' }
    }
    if ($out -match 'found problems' -or ($r.ExitCode -ne $null -and $r.ExitCode -ne 0)) {
        Add-Finding ('chkdsk found file system problems on ' + $sysDrive + '. Schedule an offline "chkdsk /f" (reboot-time) WITH customer approval; full output is in the run log.')
        Add-CustomerWarning ('File system errors were found on ' + $sysDrive + '; an offline repair (with reboot) is recommended.')
        return @{ Status = 'REVIEW'; Detail = 'Problems found (exit code ' + $r.ExitCode + ') - see findings' }
    }
    return @{ Status = 'OK'; Detail = 'Completed, exit code ' + $r.ExitCode }
}

# ---------------------------------------------------------------------------
# Step 7: DISM RestoreHealth
# ---------------------------------------------------------------------------
function Step-Dism {
    $r = Invoke-CapturedProcess -FilePath (Get-SystemExePath 'Dism.exe') `
        -ArgumentString '/Online /Cleanup-Image /RestoreHealth' `
        -TimeoutMinutes $script:DismTimeoutMinutes `
        -Activity 'DISM /RestoreHealth'

    Write-Log ('DISM output follows:' + [Environment]::NewLine + $r.Output)

    if ($r.TimedOut) {
        return @{ Status = 'FAIL'; Detail = 'Timed out after ' + $script:DismTimeoutMinutes + 'm' }
    }
    $out = ('' + $r.Output)

    if ($out -match 'The restore operation completed successfully') {
        if ($out -match 'corruption was repaired') {
            Add-Finding 'DISM repaired component store corruption.'
            return @{ Status = 'OK'; Detail = 'Corruption found and repaired' }
        }
        return @{ Status = 'OK'; Detail = 'Component store healthy / restore completed' }
    }
    if ($out -match 'No component store corruption detected') {
        return @{ Status = 'OK'; Detail = 'No corruption detected' }
    }

    $code = ''
    if ($out -match 'Error:\s*(0x[0-9A-Fa-f]+|\d+)') { $code = $Matches[1] }
    elseif ($r.ExitCode -ne $null -and $r.ExitCode -ne 0) { $code = ('' + $r.ExitCode) }

    if ($code -match '800f081f' -or $out -match 'source files could not be found') {
        Add-Finding 'DISM could not find repair source files (0x800f081f). Needs internet/Windows Update access or install media; note on the ticket.'
        Add-CustomerWarning 'Windows component store corruption could not be repaired offline.'
        return @{ Status = 'REVIEW'; Detail = 'Repair sources unavailable (0x800f081f)' }
    }
    Add-Finding ('DISM RestoreHealth did not complete cleanly (code ' + $code + '); full output is in the run log.')
    Add-CustomerWarning 'Windows component store corruption may remain unrepaired.'
    return @{ Status = 'FAIL'; Detail = 'Did not complete (code ' + $code + ')' }
}

# ---------------------------------------------------------------------------
# Step 8: SFC /scannow
# ---------------------------------------------------------------------------
function Step-Sfc {
    # sfc.exe writes UTF-16 to stdout; read it as Unicode or the captured
    # text is unreadable ("C h e c k i n g ...").
    $r = Invoke-CapturedProcess -FilePath (Get-SystemExePath 'sfc.exe') `
        -ArgumentString '/scannow' `
        -TimeoutMinutes $script:SfcTimeoutMinutes `
        -ReaderEncoding ([System.Text.Encoding]::Unicode) `
        -Activity 'SFC /scannow'

    Write-Log ('SFC output follows:' + [Environment]::NewLine + $r.Output)

    if ($r.TimedOut) {
        return @{ Status = 'FAIL'; Detail = 'Timed out after ' + $script:SfcTimeoutMinutes + 'm' }
    }
    $out = ('' + $r.Output)

    if ($out -match 'did not find any integrity violations') {
        return @{ Status = 'OK'; Detail = 'No integrity violations' }
    }
    if ($out -match 'successfully repaired') {
        Add-Finding 'SFC found corrupt system files and repaired them. Details in CBS.log (C:\Windows\Logs\CBS).'
        return @{ Status = 'OK'; Detail = 'Corrupt files found and repaired' }
    }
    if ($out -match 'unable to fix') {
        Add-Finding 'SFC found corrupt system files it could NOT fix. Check C:\Windows\Logs\CBS\CBS.log; consider an in-place repair install.'
        Add-CustomerWarning 'System file corruption remains that automated repair could not fix.'
        return @{ Status = 'FAIL'; Detail = 'Corrupt files SFC could not fix' }
    }
    if ($out -match 'repair pending') {
        Add-CustomerWarning 'A reboot is required before system file repair can run; SFC was skipped by Windows.'
        return @{ Status = 'REVIEW'; Detail = 'Blocked: a system repair is pending a reboot' }
    }
    if ($out -match 'could not perform the requested operation') {
        return @{ Status = 'FAIL'; Detail = 'SFC could not run (try after reboot)' }
    }
    return @{ Status = 'REVIEW'; Detail = 'Unrecognized result (exit code ' + $r.ExitCode + ') - see run log' }
}

# ---------------------------------------------------------------------------
# Step 4: Browser caches
#
# On a machine a few years old this is usually the single largest reclaimable
# item, and it was being missed entirely. Runs over EVERY profile under
# C:\Users, not just the tech's own login.
#
# The hard rule here: delete the CONTENTS of cache directories only. Never the
# profile directory, and never a credential or history file. Wiping a
# customer's saved logins turns a cleanup into a callback.
# ---------------------------------------------------------------------------

# Belt and braces. Nothing below should ever walk into one of these, because
# only cache directories are ever enumerated - but a wildcard that matched
# wrongly once would cost a customer their saved passwords, so every candidate
# file is checked against this list before it is deleted.
$script:NeverDeleteNames = @(
    'cookies', 'cookies-journal', 'login data', 'login data-journal',
    'web data', 'web data-journal', 'history', 'history-journal',
    'bookmarks', 'bookmarks.bak', 'places.sqlite', 'places.sqlite-wal',
    'key3.db', 'key4.db', 'logins.json', 'signons.sqlite', 'formhistory.sqlite'
)

function Test-SafeToDelete {
    param([string]$Name)
    return (-not ($script:NeverDeleteNames -contains $Name.ToLower()))
}

# Deletes the contents of one directory, leaving the directory itself. Returns
# bytes actually removed.
function Clear-DirectoryContents {
    param([string]$Path)
    $freed = [long]0
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $freed }
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        if (-not (Test-SafeToDelete $f.Name)) {
            Write-Log ('SAFETY: refused to delete ' + $f.FullName)
            continue
        }
        $len = [long]$f.Length
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $freed += $len
        } catch {
            # Locked by a running browser, or in use. Skipped, not fatal.
        }
    }
    # Empty subdirectories only; the cache directory itself always survives.
    $subs = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue) |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($d in $subs) {
        try { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop } catch { }
    }
    return $freed
}

# Real user profiles under C:\Users. Skips the service/template profiles and
# anything that is a reparse point - the legacy junctions loop forever.
function Get-UserProfileDirs {
    $skip = @('public', 'default', 'default user', 'all users', 'defaultaccount', 'wdagutilityaccount')
    $root = Join-Path $env:SystemDrive 'Users'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            ($skip -notcontains $_.Name.ToLower()) -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        })
}

# Browsers must be closed or the deletes fail silently and the step reports a
# useless zero.
#
# Edge in particular is almost always running: Windows keeps background
# msedge processes alive for startup boost and web widgets even when nobody
# has opened a browser, so "just close it" is not something a tech can do
# from the taskbar. Hence the CLOSE option - but only ever after the tech
# confirms, because open tabs may hold unsaved work.
$script:BrowserProcessNames = @('chrome', 'msedge', 'firefox', 'brave')

function Get-RunningBrowsers {
    $found = @()
    foreach ($n in $script:BrowserProcessNames) {
        $procs = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            $found += New-Object PSObject -Property @{ Name = $n; Count = $procs.Count }
        }
    }
    return $found
}

function Format-BrowserList {
    param($Running)
    return (($Running | ForEach-Object { $_.Name + ' (' + $_.Count + ')' }) -join ', ')
}

# Graceful first, force second. CloseMainWindow asks the browser to shut down
# the way clicking the X does, so it saves its session and the customer gets
# their tabs back on next launch; a straight kill can lose them. Background
# processes have no main window and never respond to it, so whatever is left
# after the grace period is force-stopped.
function Stop-Browsers {
    $gracefulAsked = 0
    foreach ($n in $script:BrowserProcessNames) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            try {
                if ($p.MainWindowHandle -ne 0) {
                    [void]$p.CloseMainWindow()
                    $gracefulAsked++
                }
            } catch { }
        }
    }
    if ($gracefulAsked -gt 0) {
        Write-Info ('  Asked ' + $gracefulAsked + ' browser window(s) to close and save their session...')
        # Up to 15s for a clean shutdown; long enough for a session save, short
        # enough that the tech is not left watching a frozen console.
        for ($i = 0; $i -lt 30; $i++) {
            if (@(Get-RunningBrowsers).Count -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
    }

    $forced = 0
    foreach ($n in $script:BrowserProcessNames) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                $forced++
            } catch {
                # Already gone between the enumerate and the stop, or protected.
            }
        }
    }
    if ($forced -gt 0) {
        Write-Info ('  Force-closed ' + $forced + ' remaining process(es) (background tasks with no window).')
    }
    # Windows does not release the file handles the instant a process dies,
    # and this step is all about deleting files those handles hold open.
    Start-Sleep -Seconds 3
    Write-Log ('Browser close: ' + $gracefulAsked + ' asked gracefully, ' + $forced + ' forced.')
    return @(Get-RunningBrowsers)
}

function Wait-ForBrowsersClosed {
    while ($true) {
        $running = @(Get-RunningBrowsers)
        if ($running.Count -eq 0) { return $true }

        Write-Host ''
        Write-Caution ('  Browsers running: ' + (Format-BrowserList $running))
        Write-Caution '  Their caches cannot be cleared while these are open - the'
        Write-Caution '  deletes fail silently rather than erroring.'
        Write-Host ''
        Write-Host '  Edge normally has background processes running even with no'
        Write-Host '  window open, so this is expected rather than the customer'
        Write-Host '  having left something running.'
        Write-Host ''
        Write-Host '    CLOSE  - close them now. Open windows are asked to shut down'
        Write-Host '             first so tabs are saved and restored next launch;'
        Write-Host '             only background processes get force-closed.'
        Write-Host '    SKIP   - leave browser caches alone and move on'
        Write-Host '    Enter  - re-check (if you would rather close them yourself)'
        Write-Host ''
        Write-Caution '  Check with the customer first if a window has unsaved work.'
        $answer = ('' + (Read-Host '  CLOSE, SKIP, or Enter to re-check')).Trim().ToUpper()

        if ($answer -eq 'SKIP') { return $false }
        if ($answer -eq 'CLOSE') {
            $left = Stop-Browsers
            if ($left.Count -eq 0) {
                Write-Good '  All browsers closed.'
                return $true
            }
            # Refused to die: usually a hung process or one held by another
            # user session. Loop rather than plough on into silent failures.
            Write-Caution ('  Still running after a forced close: ' + (Format-BrowserList $left))
            Write-Caution '  Another logged-in user may have them open.'
        }
    }
}

function Step-BrowserCache {
    if (-not (Wait-ForBrowsersClosed)) {
        return @{ Status = 'SKIP'; Detail = 'Skipped by tech - browsers left open' }
    }

    # Cache directories, relative to a user profile. The '*' is a browser
    # profile wildcard (Default, Profile 1, Profile 2...) and is enumerated -
    # assuming Default misses every secondary profile on the machine.
    $dirPatterns = @(
        @{ Cat = 'Chrome';   Rel = 'AppData\Local\Google\Chrome\User Data\*\Cache' },
        @{ Cat = 'Chrome';   Rel = 'AppData\Local\Google\Chrome\User Data\*\Code Cache' },
        @{ Cat = 'Edge';     Rel = 'AppData\Local\Microsoft\Edge\User Data\*\Cache' },
        @{ Cat = 'Edge';     Rel = 'AppData\Local\Microsoft\Edge\User Data\*\Code Cache' },
        @{ Cat = 'Brave';    Rel = 'AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Cache' },
        @{ Cat = 'Firefox';  Rel = 'AppData\Roaming\Mozilla\Firefox\Profiles\*\cache2' },
        @{ Cat = 'INetCache'; Rel = 'AppData\Local\Microsoft\Windows\INetCache' }
    )
    # Thumbnail caches are loose files, not a directory to empty.
    $filePatterns = @(
        @{ Cat = 'Thumbnails'; Rel = 'AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db' }
    )

    $byCat = @{}
    $profiles = @(Get-UserProfileDirs)
    Write-Info ('  Profiles to process: ' + $profiles.Count)

    foreach ($prof in $profiles) {
        Write-Info ('  ' + $prof.Name)
        foreach ($p in $dirPatterns) {
            # Resolve-Path expands the profile wildcard; -ErrorAction
            # SilentlyContinue because most machines have only some browsers.
            $matches = @(Resolve-Path -Path (Join-Path $prof.FullName $p.Rel) -ErrorAction SilentlyContinue)
            foreach ($m in $matches) {
                $freed = Clear-DirectoryContents -Path $m.Path
                if ($freed -gt 0) {
                    if (-not $byCat.ContainsKey($p.Cat)) { $byCat[$p.Cat] = [long]0 }
                    $byCat[$p.Cat] += $freed
                }
            }
        }
        foreach ($p in $filePatterns) {
            $matches = @(Resolve-Path -Path (Join-Path $prof.FullName $p.Rel) -ErrorAction SilentlyContinue)
            foreach ($m in $matches) {
                try {
                    $item = Get-Item -LiteralPath $m.Path -Force -ErrorAction Stop
                    if (-not (Test-SafeToDelete $item.Name)) { continue }
                    $len = [long]$item.Length
                    Remove-Item -LiteralPath $m.Path -Force -ErrorAction Stop
                    if (-not $byCat.ContainsKey($p.Cat)) { $byCat[$p.Cat] = [long]0 }
                    $byCat[$p.Cat] += $len
                } catch { }
            }
        }
    }

    $total = [long]0
    foreach ($k in $byCat.Keys) { $total += $byCat[$k] }
    Add-Reclaimed $total

    # Per-category breakdown goes to the log and the findings only if it is
    # worth reading; the step line carries the headline number.
    $parts = @()
    foreach ($k in ($byCat.Keys | Sort-Object)) {
        $parts += ($k + ' ' + (Format-Bytes $byCat[$k]))
    }
    if ($parts.Count -gt 0) {
        Write-Info ('  Reclaimed: ' + ($parts -join ', '))
        Write-Log ('Browser cache breakdown: ' + ($parts -join ', '))
    }

    if ($total -eq 0) {
        return @{ Status = 'OK'; Detail = 'Nothing to reclaim' }
    }
    return @{ Status = 'OK'; Detail = ('Freed ' + (Format-Bytes $total) + ' over ' + $profiles.Count + ' profile(s)') }
}

# ---------------------------------------------------------------------------
# Step 9: Component store cleanup
#
# Reclaims superseded WinSxS components - routinely 3-8 GB on a machine that
# has been through several feature updates, often more than everything else in
# this script combined.
#
# Deliberately NO /ResetBase. That makes every currently installed update
# permanently uninstallable, which is not a decision to take silently on a
# customer's machine.
# ---------------------------------------------------------------------------
function Step-ComponentCleanup {
    $before = Get-FreeSpaceBytes
    $r = Invoke-CapturedProcess -FilePath (Get-SystemExePath 'Dism.exe') `
        -ArgumentString '/Online /Cleanup-Image /StartComponentCleanup' `
        -TimeoutMinutes $script:ComponentCleanupTimeoutMinutes `
        -Activity 'DISM component store cleanup'

    Write-Log ('DISM StartComponentCleanup output follows:' + [Environment]::NewLine + $r.Output)
    $after = Get-FreeSpaceBytes
    $delta = Add-ReclaimedFromFreeSpace $before $after

    if ($r.TimedOut) {
        return @{ Status = 'FAIL'; Detail = 'Timed out after ' + $script:ComponentCleanupTimeoutMinutes + 'm' }
    }
    $out = ('' + $r.Output)
    if ($out -match 'The operation completed successfully') {
        return @{ Status = 'OK'; Detail = ('Reclaimed ' + (Format-Bytes $delta)) }
    }
    $code = ''
    if ($out -match 'Error:\s*(0x[0-9A-Fa-f]+|\d+)') { $code = $Matches[1] }
    elseif ($r.ExitCode -ne $null -and $r.ExitCode -ne 0) { $code = ('' + $r.ExitCode) }
    if ($code) {
        Add-Finding ('DISM component store cleanup did not complete cleanly (code ' + $code + '); full output is in the run log.')
        return @{ Status = 'REVIEW'; Detail = ('Incomplete (code ' + $code + '), reclaimed ' + (Format-Bytes $delta)) }
    }
    return @{ Status = 'OK'; Detail = ('Reclaimed ' + (Format-Bytes $delta)) }
}

# ---------------------------------------------------------------------------
# Step 10: Windows disk cleanup
#
# cleanmgr /sagerun:1 needs /sageset:1 to have been run interactively on the
# machine first, which makes it useless unattended. So the selection is
# configured programmatically instead: StateFlags0001 under each VolumeCaches
# subkey, then /sagerun:1.
#
# The subkeys present vary by Windows version, so they are enumerated rather
# than hardcoded. Everything not explicitly wanted is set to 0 rather than
# just left alone: a previous /sageset on this machine could otherwise leave a
# category enabled and have cleanmgr empty the recycle bin behind our back.
# ---------------------------------------------------------------------------
$script:VolumeCachesKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'

# Matched case-insensitively against the subkey name. 'Windows Error
# Reporting' is a prefix match because the variants differ between versions
# (Queue, Archive, System, Per user...).
$script:CleanMgrWanted = @(
    'Temporary Files',
    'Update Cleanup',
    'Windows Error Reporting',
    'Delivery Optimization Files',
    'Thumbnail Cache',
    'Old ChkDsk Files',
    'Device Driver Packages',
    'Previous Installations',
    'Temporary Setup Files'
)

# Never enabled, whatever else matches. Downloaded Program Files is excluded by
# request; the recycle bin is excluded because step 3 already empties it
# deliberately and a second, silent pass over user data is not wanted here.
$script:CleanMgrNeverWanted = @(
    'Downloaded Program Files',
    'Recycle Bin',
    'DownloadsFolder',
    'User file versions'
)

function Test-CleanMgrWanted {
    param([string]$Name)
    foreach ($no in $script:CleanMgrNeverWanted) {
        if ($Name -like ('*' + $no + '*')) { return $false }
    }
    foreach ($yes in $script:CleanMgrWanted) {
        if ($Name -like ($yes + '*')) { return $true }
    }
    return $false
}

function Step-WindowsCleanup {
    if (-not (Test-Path -LiteralPath $script:VolumeCachesKey)) {
        return @{ Status = 'REVIEW'; Detail = 'VolumeCaches registry key not present' }
    }

    $enabled = @()
    $disabled = 0
    foreach ($sub in @(Get-ChildItem -LiteralPath $script:VolumeCachesKey -ErrorAction SilentlyContinue)) {
        $name = $sub.PSChildName
        $want = Test-CleanMgrWanted $name
        try {
            # StateFlags0001 pairs with /sagerun:1. It is inert for any other
            # cleanmgr invocation, so this does not change what a manual Disk
            # Cleanup run on this machine would do.
            New-ItemProperty -LiteralPath $sub.PSPath -Name 'StateFlags0001' `
                -Value $(if ($want) { 2 } else { 0 }) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            if ($want) { $enabled += $name } else { $disabled++ }
        } catch {
            Write-Log ('Could not set StateFlags0001 on ' + $name + ': ' + $_.Exception.Message)
        }
    }
    Write-Log ('cleanmgr categories enabled: ' + ($enabled -join ', '))
    Write-Log ('cleanmgr categories explicitly disabled: ' + $disabled)
    Write-Info ('  Enabled ' + $enabled.Count + ' cleanup categories, disabled ' + $disabled)

    if ($enabled -contains 'Previous Installations') {
        Add-CustomerWarning 'Windows disk cleanup removed the Windows.old rollback folder, so this machine can no longer roll back its last feature update. Normal for a cleanup, but the customer loses that option.'
    }

    $before = Get-FreeSpaceBytes
    # cleanmgr prints no progress at all, so the runner falls back to showing
    # elapsed time rather than a percentage.
    $r = Invoke-CapturedProcess -FilePath (Get-SystemExePath 'cleanmgr.exe') `
        -ArgumentString ('/sagerun:1 /d ' + $script:SystemDriveLetter) `
        -TimeoutMinutes $script:CleanMgrTimeoutMinutes `
        -Activity 'Windows disk cleanup'
    $after = Get-FreeSpaceBytes
    $delta = Add-ReclaimedFromFreeSpace $before $after

    Write-Log ('cleanmgr free space before ' + (Format-Bytes $before) + ', after ' + (Format-Bytes $after))

    if ($r.TimedOut) {
        Add-Finding ('Windows disk cleanup hit the ' + $script:CleanMgrTimeoutMinutes + '-minute limit and was stopped; it may not have finished.')
        return @{ Status = 'REVIEW'; Detail = ('Timed out, reclaimed ' + (Format-Bytes $delta)) }
    }
    return @{ Status = 'OK'; Detail = ('Reclaimed ' + (Format-Bytes $delta) + ' (' + $enabled.Count + ' categories)') }
}

# ---------------------------------------------------------------------------
# Shared ClamAV logic, also used by Scan-Clam.ps1 for targeted re-scans after
# remediation. Loaded rather than duplicated so the two can never drift.
# Dot-sourced here, after the logging helpers and Invoke-CapturedProcess it
# calls, and before any step that uses it.
# ---------------------------------------------------------------------------
$script:ClamLib = Join-Path $script:ScriptRoot 'ClamAV.Lib.ps1'
if (Test-Path -LiteralPath $script:ClamLib) {
    . $script:ClamLib
} else {
    # Missing library is not fatal: every other step still runs, and the
    # ClamAV step reports itself as skipped.
    function Test-ClamAvailable { return $false }
}

# ---------------------------------------------------------------------------
# Step runner. A step failure records and moves on - it never aborts the run.
# ---------------------------------------------------------------------------
function Invoke-Step {
    param(
        [int]$Number,
        [string]$Name,
        [scriptblock]$Body
    )
    Write-Host ''
    Write-Host ('---- Step ' + $Number + ' of ' + $script:TotalSteps + ': ' + $Name + ' ' + ('-' * [math]::Max(1, 58 - $Name.Length))) -ForegroundColor Cyan
    try {
        Write-Progress -Id 1 -Activity 'Bench Cleanup' `
            -Status ('Step ' + $Number + ' of ' + $script:TotalSteps + ' - ' + $Name) `
            -PercentComplete ([int](($Number - 1) * 100 / $script:TotalSteps))
    } catch { }
    Write-Log ('=== Step ' + $Number + '/' + $script:TotalSteps + ': ' + $Name + ' ===')

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = $null
    if ($script:AbortRun) {
        $res = @{ Status = 'SKIP'; Detail = 'Run stopped at drive health gate' }
    } else {
        try {
            $res = & $Body
        } catch {
            # Belt and braces: step functions catch their own known failures,
            # this catches the unknown ones so the chain keeps moving.
            $msg = ('' + $_.Exception.Message) -replace '\s+', ' '
            Write-Log ('Step crashed: ' + $msg + ' | ' + $_.ScriptStackTrace)
            $res = @{ Status = 'FAIL'; Detail = 'Unexpected error: ' + $msg }
        }
    }
    $sw.Stop()

    if ($res -is [System.Array]) { $res = $res[-1] }   # guard against stray pipeline output
    if (-not ($res -is [hashtable]) -or -not $res.ContainsKey('Status')) {
        $res = @{ Status = 'FAIL'; Detail = 'Step returned no result' }
    }

    $record = New-Object PSObject -Property @{
        Number   = $Number
        Name     = $Name
        Status   = ('' + $res.Status)
        Detail   = ('' + $res.Detail)
        Duration = $sw.Elapsed
    }
    [void]$script:StepResults.Add($record)

    $color = Get-StatusColor $record.Status
    Write-Host ('  -> ' + $record.Status + '  (' + (Format-Duration $record.Duration) + ')  ' + $record.Detail) -ForegroundColor $color
    Write-Log ('Result: ' + $record.Status + ' (' + (Format-Duration $record.Duration) + ') ' + $record.Detail)
}

# ---------------------------------------------------------------------------
# Summary block - the tech copies this onto the paper work order.
# ---------------------------------------------------------------------------
function Get-OverallVerdict {
    $hasRed = $false
    $hasYellow = $false
    foreach ($s in $script:StepResults) {
        if ($s.Status -eq 'THREAT' -or $s.Status -eq 'FAIL') { $hasRed = $true }
        if ($s.Status -eq 'REVIEW' -or $s.Status -eq 'SKIP') { $hasYellow = $true }
    }
    if ($script:CustomerWarnings.Count -gt 0) { $hasYellow = $true }
    if ($hasRed)    { return @{ Text = 'ATTENTION - see findings and warnings above'; Color = 'Red' } }
    if ($hasYellow) { return @{ Text = 'REVIEW - check findings before release';      Color = 'Yellow' } }
    return @{ Text = 'CLEAN - all steps passed'; Color = 'Green' }
}

function Show-Summary {
    $elapsed = (Get-Date) - $script:RunStart
    $bar = ('=' * 78)
    $thin = ('-' * 78)

    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host '  BENCH CLEANUP SUMMARY  -  copy this block onto the work order' -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ('  Machine : ' + $env:COMPUTERNAME)
    Write-Host ('  Windows : ' + $script:WindowsText)
    Write-Host ('  Date    : ' + $script:RunStart.ToString('yyyy-MM-dd HH:mm') + '    Total run time: ' + (Format-Duration $elapsed))
    Write-Host $thin

    # Fixed columns so the table stays scannable. Detail is truncated to the
    # 78-column block: it carries the headline number only, and anything that
    # needs the full story is repeated in FINDINGS below.
    $detailWidth = 78 - 42
    foreach ($s in $script:StepResults) {
        $detail = $s.Detail
        if ($detail.Length -gt $detailWidth) {
            $detail = $detail.Substring(0, $detailWidth - 2) + '..'
        }
        Write-Host ('  {0} {1} ' -f ('' + $s.Number).PadLeft(2), $s.Name.PadRight(20).Substring(0, 20)) -NoNewline
        Write-Host ($s.Status.PadRight(7)) -NoNewline -ForegroundColor (Get-StatusColor $s.Status)
        Write-Host ((Format-Duration $s.Duration).PadRight(9) + $detail)
    }

    Write-Host $thin
    # The one number the customer sees value in, so it gets its own line
    # rather than being buried in a step detail.
    Write-Host '  TOTAL SPACE RECLAIMED: ' -NoNewline
    Write-Host (Format-Bytes $script:TotalReclaimed) -ForegroundColor Green
    Write-Host $thin
    Write-Host '  FINDINGS:' -ForegroundColor Cyan
    if ($script:Findings.Count -eq 0) {
        Write-Host '    (none)' -ForegroundColor Green
    } else {
        foreach ($f in $script:Findings) {
            Write-Wrapped -Text $f -FirstPrefix '    - ' -ContinuePrefix '      ' -Width 78 -Color 'Yellow'
        }
    }

    Write-Host '  WARNINGS - RELAY TO CUSTOMER:' -ForegroundColor Cyan
    if ($script:CustomerWarnings.Count -eq 0) {
        Write-Host '    (none)' -ForegroundColor Green
    } else {
        foreach ($w in $script:CustomerWarnings) {
            Write-Wrapped -Text $w -FirstPrefix '    - ' -ContinuePrefix '      ' -Width 78 -Color 'Red'
        }
    }

    $verdict = Get-OverallVerdict
    Write-Host $thin
    Write-Host ('  VERDICT: ' + $verdict.Text) -ForegroundColor $verdict.Color
    Write-Host $bar -ForegroundColor Cyan
    if ($script:LogPath) {
        # Full chkdsk/DISM/SFC output lives here; it is the only way to
        # second-guess a result later. Path on its own line because a real
        # %TEMP% path plus a prefix overflows even a 120-column console.
        Write-Host '  Full run log (on this machine, not the stick):' -ForegroundColor DarkGray
        Write-Host ('    ' + $script:LogPath) -ForegroundColor DarkGray
    }
    Write-Log ('VERDICT: ' + $verdict.Text)
}


# ===========================================================================
# Main
# ===========================================================================
try {
    Disable-QuickEdit
    Initialize-WorkDir

    $script:WindowsText = Get-WindowsVersionText

    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host '  BENCH CLEANUP RUNNER' -ForegroundColor Cyan
    Write-Host ('  ' + $env:COMPUTERNAME + '  |  ' + $script:WindowsText + '  |  ' + $script:RunStart.ToString('yyyy-MM-dd HH:mm'))
    Write-Host ('=' * 78) -ForegroundColor Cyan

    if (-not (Test-IsAdmin)) {
        Write-Host ''
        Write-Alert '  This script must run elevated. Close this window and double-click'
        Write-Alert '  Run-Cleanup.cmd, which relaunches itself as administrator.'
        # return skips to finally, which pauses; the window stays readable.
        return
    }

    # Defender cmdlet availability, checked once. Missing on stripped-down
    # or heavily tampered installs; steps 4 and 5 degrade gracefully.
    try {
        if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
            $null = Get-MpComputerStatus -ErrorAction Stop
            $script:DefenderAvailable = $true
        }
    } catch {
        Write-Caution '  Defender cmdlets are not usable on this machine; steps 4-5 will be limited.'
    }

    Invoke-Step -Number  1 -Name 'Drive health gate'   -Body { Step-DriveHealth }
    Invoke-Step -Number  2 -Name 'Restore point'       -Body { Step-RestorePoint }
    Invoke-Step -Number  3 -Name 'Temp cleanup'        -Body { Step-TempCleanup }
    Invoke-Step -Number  4 -Name 'Browser caches'      -Body { Step-BrowserCache }
    Invoke-Step -Number  5 -Name 'Defender defs'       -Body { Step-DefinitionUpdate }
    Invoke-Step -Number  6 -Name 'ClamAV scan'         -Body { Step-ClamScan }
    Invoke-Step -Number  7 -Name 'Disk check (online)' -Body { Step-DiskCheck }
    Invoke-Step -Number  8 -Name 'DISM RestoreHealth'  -Body { Step-Dism }
    # SFC runs last so it verifies integrity AFTER the two cleanup steps have
    # finished removing components, rather than before.
    Invoke-Step -Number  9 -Name 'Component cleanup'   -Body { Step-ComponentCleanup }
    Invoke-Step -Number 10 -Name 'Windows disk cleanup' -Body { Step-WindowsCleanup }
    Invoke-Step -Number 11 -Name 'SFC /scannow'        -Body { Step-Sfc }

    try { Write-Progress -Id 1 -Activity 'Bench Cleanup' -Completed } catch { }

    # Reboot-pending state matters to the customer handoff, so check it last.
    if (Test-PendingReboot) {
        Add-CustomerWarning 'A Windows reboot is pending on this machine; reboot before release and re-verify stability.'
    }

    Show-Summary
    if ($script:AbortRun) {
        Write-Host ''
        Write-Alert '  Run was stopped at the drive health gate. Take this to the service'
        Write-Alert '  writer as a drive replacement conversation.'
    }
} catch {
    # Whole-body catch: print enough to diagnose over the phone.
    Write-Host ''
    Write-Host ('FATAL ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('  At line  : ' + $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
    Write-Host ('  Stack    : ' + $_.ScriptStackTrace) -ForegroundColor Red
    Write-Log ('FATAL: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber)
} finally {
    # Always pause so the window - and the summary - survive. The .cmd
    # launcher has its own "pause" as the last line of defence against a
    # parse error that kills the whole script before this line.
    try { Write-Progress -Id 1 -Activity 'Bench Cleanup' -Completed } catch { }
    Write-Host ''
    try { $null = Read-Host 'Run complete - press Enter to close this window' } catch { }
}
