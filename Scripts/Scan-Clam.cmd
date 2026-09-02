@echo off
rem =====================================================================
rem Scan-Clam.cmd - ClamAV: update signatures (verified), then scan.
rem
rem Usage:  Scripts\Scan-Clam.cmd                 standard target set
rem         Scripts\Scan-Clam.cmd "C:\Some\Path"   one path instead
rem
rem This lives in Scripts\ rather than the stick root because it is NOT
rem part of a normal job - Run-Cleanup.cmd already runs a ClamAV scan as
rem one of its steps. This is the re-scan tool: after you remove something
rem the cleanup found, point this at that folder to confirm it is gone.
rem
rem It elevates (needed to read every user profile) and bypasses execution
rem policy. The trailing "pause" keeps the window open even if the .ps1
rem dies on a parse error before its own try/finally can run.
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
rem Both files are in Scripts\ now, so this resolves beside itself.
if not exist "%~dp0Scan-Clam.ps1" (
    echo.
    echo Cannot find Scan-Clam.ps1 next to this launcher.
    echo This folder is incomplete - re-copy the stick folder, or run
    echo Update.cmd on the bench machine to restore it.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scan-Clam.ps1" %*
pause
