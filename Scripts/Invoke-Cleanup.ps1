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

# This script lives in Scripts\, but Tools\ sits beside that folder at the
# stick root - so the checklist must print the PARENT. Getting this wrong
# hands the tech a Tools path that does not exist, and it is pasted straight
# into the ClamAV command, so it fails at the point of use rather than here.
$script:StickRoot = $null
try {
    $script:StickRoot = Split-Path -Parent $script:ScriptRoot
} catch { }
# Split-Path returns empty at a drive root; fall back rather than print ''.
if (-not $script:StickRoot) { $script:StickRoot = $script:ScriptRoot }

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

# Timeouts. Every one of these is enforced by a loop that is guaranteed to
# come back around (see Invoke-CapturedProcess / Invoke-JobWithTimeout).
$script:SigUpdateTimeoutMinutes = 15
$script:FullScanTimeoutMinutes  = 300
$script:ChkdskTimeoutMinutes    = 90
$script:DismTimeoutMinutes      = 180
$script:SfcTimeoutMinutes       = 120

$script:TotalSteps = 8

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
    Write-Log ('Temp cleanup: ' + $totalLocked + ' file(s) in use and skipped; ' + $binNote)
    return @{ Status = 'OK'; Detail = ('Freed ' + (Format-Bytes $totalBytes) + ' (' + $totalFiles + ' files)') }
}

# ---------------------------------------------------------------------------
# Step 4: Defender definition update
# ---------------------------------------------------------------------------
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
    if ($after -ne $before) {
        return @{ Status = 'OK'; Detail = $before + ' -> ' + $after }
    }
    return @{ Status = 'OK'; Detail = 'Current: ' + $after + $ageNote }
}

# ---------------------------------------------------------------------------
# Step 5: Defender full scan
# ---------------------------------------------------------------------------
function Step-DefenderScan {
    if (-not $script:DefenderAvailable) {
        return @{ Status = 'REVIEW'; Detail = 'Defender cmdlets not available - scan skipped' }
    }

    # --- Pre-scan posture checks (read-only; never change customer config) ---
    $passive = $false
    $modeText = 'unknown'
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        $modeText = ('' + $st.AMRunningMode)
        if ($modeText -match 'Passive') { $passive = $true }
    } catch { }
    Write-Info ('  Defender running mode: ' + $modeText)

    # Third-party AV per Security Center. If one is active, Defender is
    # usually the passive engine.
    try {
        $avList = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop)
        foreach ($av in $avList) {
            if (('' + $av.displayName) -notmatch 'Windows Defender|Microsoft Defender') {
                Write-Caution ('  Third-party AV present: ' + $av.displayName)
                Add-Finding ('Third-party AV installed: ' + $av.displayName)
            }
        }
    } catch { }

    if ($passive) {
        Write-Caution '  Defender is in PASSIVE mode: it will scan and detect but NOT remediate.'
        Add-CustomerWarning 'Defender ran in passive mode (third-party AV owns protection). It detects but does not remove threats; a CLEAN result here is weaker than an active-mode scan.'
    }

    # PUA protection: READ AND REPORT ONLY. Toggling it would persistently
    # change the customer's configuration, which we never do.
    $puaNote = ''
    $puaShort = ''
    try {
        $pua = [int](Get-MpPreference -ErrorAction Stop).PUAProtection
        switch ($pua) {
            0 { $puaNote = 'PUA protection OFF';       $puaShort = 'PUA off' }
            1 { $puaNote = 'PUA protection ON (block)'; $puaShort = 'PUA block' }
            2 { $puaNote = 'PUA protection AUDIT';      $puaShort = 'PUA audit' }
            default { $puaNote = 'PUA protection value ' + $pua; $puaShort = 'PUA ' + $pua }
        }
        Write-Info ('  ' + $puaNote)
        if ($pua -eq 0) {
            Add-Finding 'PUA protection is off on this machine: the scan did not cover potentially unwanted applications. Do not change the setting; note it for the customer.'
        }
    } catch { }

    Write-Info ('  Starting full scan. This is the long step; limit ' + $script:FullScanTimeoutMinutes + ' minutes.')
    $scanStart = Get-Date
    $r = Invoke-JobWithTimeout -Body { Start-MpScan -ScanType FullScan -ErrorAction Stop } `
        -TimeoutMinutes $script:FullScanTimeoutMinutes -Activity 'Defender full scan'

    if ($r.TimedOut) {
        Add-Finding ('Defender full scan hit the ' + $script:FullScanTimeoutMinutes + '-minute limit and was stopped; result is incomplete.')
        return @{ Status = 'FAIL'; Detail = 'Timed out - INCOMPLETE' }
    }
    if ($r.Errors.Count -gt 0) {
        $msg = ('' + $r.Errors[0]) -replace '\s+', ' '
        Add-Finding ('Defender full scan failed: ' + $msg)
        return @{ Status = 'FAIL'; Detail = 'Scan failed - see findings' }
    }

    # Detections from THIS run only, filtered by time.
    $dets = @()
    try {
        $dets = @(Get-MpThreatDetection -ErrorAction Stop |
            Where-Object { $_.InitialDetectionTime -ge $scanStart })
    } catch { }

    if ($dets.Count -gt 0) {
        $names = @{}
        try {
            foreach ($t in @(Get-MpThreat -ErrorAction Stop)) {
                $names[('' + $t.ThreatID)] = ('' + $t.ThreatName)
            }
        } catch { }
        foreach ($d in $dets) {
            $n = $names[('' + $d.ThreatID)]
            if (-not $n) { $n = 'ThreatID ' + $d.ThreatID }
            $res = ''
            try { $res = ('' + (@($d.Resources) | Select-Object -First 1)) } catch { }
            Add-Finding ('Defender detected: ' + $n + '  ' + $res)
        }
        if ($passive) {
            Add-CustomerWarning 'Threats were detected while Defender was passive - they were NOT removed. Manual remediation required.'
        } else {
            Add-CustomerWarning ('Defender found and actioned ' + $dets.Count + ' threat(s). Verify quarantine in Windows Security > Protection history.')
        }
        return @{ Status = 'THREAT'; Detail = ('' + $dets.Count + ' detection(s) - see findings') }
    }

    $detail = 'No threats detected'
    if ($puaShort) { $detail += ' (' + $puaShort + ')' }
    if ($passive) {
        return @{ Status = 'REVIEW'; Detail = 'Clean but PASSIVE - weak assurance' }
    }
    return @{ Status = 'OK'; Detail = $detail }
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
    $detailWidth = 78 - 41
    foreach ($s in $script:StepResults) {
        $detail = $s.Detail
        if ($detail.Length -gt $detailWidth) {
            $detail = $detail.Substring(0, $detailWidth - 2) + '..'
        }
        Write-Host ('  {0} {1} ' -f $s.Number, $s.Name.PadRight(20).Substring(0, 20)) -NoNewline
        Write-Host ($s.Status.PadRight(7)) -NoNewline -ForegroundColor (Get-StatusColor $s.Status)
        Write-Host ((Format-Duration $s.Duration).PadRight(9) + $detail)
    }

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
    Write-Log ('VERDICT: ' + $verdict.Text)
}

# ---------------------------------------------------------------------------
# Post-script manual checklist. Each of these needs human judgement, which
# is why they are not automated.
# ---------------------------------------------------------------------------
function Show-Checklist {
    # StickRoot, not ScriptRoot: this script is in Scripts\ and Tools\ is its
    # sibling one level up. Plain concatenation, not Join-Path: Join-Path
    # throws "Cannot find drive" if the stick has been pulled, and losing the
    # checklist after a two-hour run because the tech unplugged early is not
    # acceptable.
    $toolsPath = ('' + $script:StickRoot).TrimEnd('\') + '\Tools'
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Yellow
    Write-Host '  MANUAL CHECKLIST - automated portion is done; work these by hand' -ForegroundColor Yellow
    Write-Host ('=' * 78) -ForegroundColor Yellow
    Write-Host ('  Tools folder on this stick: ' + $toolsPath)
    Write-Host ''
    Write-Host '  1. ClamAV scan. Run freshclam.exe first (updates definitions), then:'
    Write-Host ('       clamscan.exe -r -i --database="' + $toolsPath + '\ClamAV\db" C:\Users C:\ProgramData C:\Windows\Temp')
    Write-Host '     EXCLUDE OneDrive folders: Files On-Demand placeholders hydrate when'
    Write-Host '     scanned and will download the customer''s entire cloud drive.'
    Write-Host '     EXCLUDE the legacy junctions "Application Data", "Local Settings",'
    Write-Host '     "All Users", "Documents and Settings": they loop forever under -r.'
    Write-Host '  2. Autoruns (Sysinternals GUI): enable "Check VirusTotal" and "Hide'
    Write-Host '     Microsoft Entries", review everything that remains.'
    Write-Host '  3. Process Explorer: enable the VirusTotal column, review running'
    Write-Host '     processes.'
    Write-Host '  4. BleachBit (portable): browser cache and temp ONLY. Never cookies,'
    Write-Host '     saved passwords or history - wiping logged-in sessions turns a'
    Write-Host '     cleanup into a callback.'
    Write-Host '  5. Defender Offline scan: Windows Security > Virus and threat'
    Write-Host '     protection > Scan options > Microsoft Defender Antivirus (offline'
    Write-Host '     scan). Reboots the machine, about 15 minutes. This is the only step'
    Write-Host '     that inspects the disk while malware is not running.'
    Write-Host '  6. Browser extension review in every installed browser.'
    Write-Host '  7. Reboot and confirm the machine is stable before release.'
    Write-Host ''
    if ($script:LogPath) {
        # Path on its own line: a real %TEMP% path plus a prefix overflows
        # even a 120-column console and wraps into something unreadable.
        Write-Host '  Full run log (on this machine, not the stick):' -ForegroundColor DarkGray
        Write-Host ('    ' + $script:LogPath) -ForegroundColor DarkGray
    }
    Write-Host ('=' * 78) -ForegroundColor Yellow
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

    Invoke-Step -Number 1 -Name 'Drive health gate'  -Body { Step-DriveHealth }
    Invoke-Step -Number 2 -Name 'Restore point'      -Body { Step-RestorePoint }
    Invoke-Step -Number 3 -Name 'Temp cleanup'       -Body { Step-TempCleanup }
    Invoke-Step -Number 4 -Name 'Definition update'  -Body { Step-DefinitionUpdate }
    Invoke-Step -Number 5 -Name 'Defender full scan' -Body { Step-DefenderScan }
    Invoke-Step -Number 6 -Name 'Disk check (online)' -Body { Step-DiskCheck }
    Invoke-Step -Number 7 -Name 'DISM RestoreHealth' -Body { Step-Dism }
    Invoke-Step -Number 8 -Name 'SFC /scannow'       -Body { Step-Sfc }

    try { Write-Progress -Id 1 -Activity 'Bench Cleanup' -Completed } catch { }

    # Reboot-pending state matters to the customer handoff, so check it last.
    if (Test-PendingReboot) {
        Add-CustomerWarning 'A Windows reboot is pending on this machine; reboot before release and re-verify stability.'
    }

    Show-Summary
    if ($script:AbortRun) {
        Write-Host ''
        Write-Alert '  Run was stopped at the drive health gate. Take this to the service'
        Write-Alert '  writer as a drive replacement conversation. Manual checklist skipped.'
    } else {
        Show-Checklist
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
