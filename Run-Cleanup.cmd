@echo off
rem =====================================================================
rem Run-Cleanup.cmd - double-click launcher for the Bench Cleanup Runner.
rem
rem Handles the two things PowerShell cannot do for itself from a USB
rem stick: elevation, and execution policy (-ExecutionPolicy Bypass so a
rem locked-down machine policy cannot block the run). The trailing
rem "pause" keeps this window open even if the .ps1 dies on a parse
rem error before its own try/finally can run - never rely on -NoExit,
rem because an "exit" inside the script closes the window regardless.
rem
rem This file must stay pure ASCII with no byte order mark: cmd.exe
rem misreads a BOM as part of the first command.
rem =====================================================================

rem "net session" succeeds only when already elevated.
net session >nul 2>&1
if %errorlevel% == 0 goto :run

echo Requesting administrator rights (accept the UAC prompt)...
powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-Cleanup.ps1"
pause
