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
#   Scripts\Scan-Clam.cmd "C:\Users\jane\Downloads"
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
# Shared ClamAV logic, also used by Invoke-Cleanup.ps1's ClamAV step. Loaded
# here rather than duplicated so the standalone re-scan and the cleanup chain
# can never behave differently. Dot-sourced AFTER the helpers above, which it
# calls.
# ---------------------------------------------------------------------------
$script:ClamLib = Join-Path $script:ScriptRoot 'ClamAV.Lib.ps1'
if (-not (Test-Path -LiteralPath $script:ClamLib)) {
    throw ('ClamAV.Lib.ps1 not found beside this script at ' + $script:ClamLib +
           '. The stick folder is incomplete - run Update.cmd on the bench machine.')
}
. $script:ClamLib

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

    Initialize-ClamPaths
    Write-Info ('  ClamAV   : ' + $script:ClamRoot)
    Write-Info ('  Database : ' + $script:DataDir)

    # ---- Update, verified ------------------------------------------------
    Write-Host ''
    Write-Host '---- STEP 1 of 2 - Updating signatures ---------------------------------' -ForegroundColor Cyan
    $upd = Invoke-ClamUpdateVerified -Interactive $true
    $dbAfter = $upd.Db
    $updateOk = $upd.Ok
    $staleAccepted = $upd.StaleAccepted
    if ($upd.Aborted) {
        Write-Host ''
        Write-Alert '  Stopped. No scan was run. Fix the definitions and try again.'
        return
    }

    # ---- Scan ------------------------------------------------------------
    Write-Host ''
    Write-Host '---- STEP 2 of 2 - Scanning --------------------------------------------' -ForegroundColor Cyan
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
    Write-Info ('  Targets : ' + ($targets -join ', '))
    Write-Info ('  Log     : ' + $script:ScanLog)
    Write-Host ''
    Write-Host '  Only infected files are printed. Silence means nothing found.'
    Write-Host ('  Typically 20-40 minutes; hard limit ' + $script:ScanTimeoutMinutes + ' minutes.')

    $scan = Invoke-ClamScan -Targets $targets -ScanLogPath $script:ScanLog `
        -TimeoutMinutes $script:ScanTimeoutMinutes

    # ---- Result block ----------------------------------------------------
    $bar = ('=' * 78)
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host '  CLAMAV RESULT  -  copy onto the work order' -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ('  Machine  : ' + $env:COMPUTERNAME)
    Write-Host ('  Date     : ' + $script:RunStart.ToString('yyyy-MM-dd HH:mm') + '    Scan time: ' + (Format-Duration $scan.Elapsed))
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

    if ($scan.Scanned -ne $null) {
        $line = '  Files    : ' + $scan.Scanned + ' scanned'
        if ($scan.DataRead) { $line += ', ' + $scan.DataRead }
        Write-Host $line
    }
    if ($scan.Skipped -gt 0) {
        Write-Host ('  Skipped  : ' + $scan.Skipped + ' unreadable (locked by running processes - expected)')
    }
    Write-Host ('-' * 78)

    if ($scan.TimedOut) {
        Write-Alert ('  RESULT: INCOMPLETE - hit the ' + $script:ScanTimeoutMinutes + '-minute limit')
    } elseif ($scan.Infected -ne $null -and $scan.Infected -gt 0) {
        Write-Alert ('  RESULT: ' + $scan.Infected + ' INFECTED FILE(S)')
        foreach ($h in $scan.Hits) { Write-Alert ('    ' + $h.Trim()) }
        Write-Host ''
        Write-Alert '  ClamAV does NOT remove anything. Every FOUND file must be'
        Write-Alert '  handled by hand, then re-scan that path:'
        Write-Alert '      Scripts\Scan-Clam.cmd "C:\path\to\folder"'
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
