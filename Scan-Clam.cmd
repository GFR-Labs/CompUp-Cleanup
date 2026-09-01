@echo off
rem =====================================================================
rem Scan-Clam.cmd - ClamAV: update signatures (verified), then scan.
rem
rem Usage:  Scan-Clam.cmd                 scans the standard target set
rem         Scan-Clam.cmd "C:\Some\Path"  scans one path instead
rem
rem Run this on the customer machine. It elevates (needed to read every
rem user profile) and bypasses execution policy. The trailing "pause"
rem keeps the window open even if the .ps1 dies on a parse error before
rem its own try/finally can run.
rem
rem No Setup step is needed: if freshclam.conf is missing the script
rem writes a minimal one. An existing conf is never overwritten.
rem
rem This file must stay pure ASCII with no byte order mark: cmd.exe
rem misreads a BOM as part of the first command.
rem =====================================================================
title ClamAV Update and Scan

net session >nul 2>&1
if %errorlevel% == 0 goto :run

rem Re-launch elevated, carrying any target path through. %* is passed as
rem a single quoted argument list; without it, "scan just this folder"
rem would silently become a full scan after the UAC prompt.
echo Requesting administrator rights (accept the UAC prompt)...
if "%~1"=="" (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
) else (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
)
exit /b

:run
if not exist "%~dp0Scripts\Scan-Clam.ps1" (
    echo.
    echo Cannot find Scripts\Scan-Clam.ps1 next to this launcher.
    echo This folder is incomplete - re-copy the stick folder, or run
    echo Update.cmd on the bench machine to restore it.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Scan-Clam.ps1" %*
pause
