@echo off
rem =====================================================================
rem Scan-Clam.cmd - ClamAV definition update (verified) then scan.
rem
rem Run this on the customer machine as the manual ClamAV step in the SOP.
rem Elevates (needed to read every user profile) and bypasses execution
rem policy. The trailing "pause" keeps the window open even if the .ps1
rem dies on a parse error before its own try/finally can run.
rem
rem This file must stay pure ASCII with no byte order mark: cmd.exe
rem misreads a BOM as part of the first command.
rem =====================================================================

net session >nul 2>&1
if %errorlevel% == 0 goto :run

echo Requesting administrator rights (accept the UAC prompt)...
powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
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

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Scan-Clam.ps1"
pause
