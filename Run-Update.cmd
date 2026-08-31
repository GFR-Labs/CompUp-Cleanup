@echo off
rem =====================================================================
rem Run-Update.cmd - refresh this stick from the GitHub repo.
rem
rem Run on the BENCH machine (needs internet). No elevation needed: it
rem only writes to the stick. The trailing "pause" keeps the window open
rem even if the .ps1 fails to parse.
rem
rem This file must stay pure ASCII with no byte order mark: cmd.exe
rem misreads a BOM as part of the first command.
rem =====================================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-FromGitHub.ps1"
pause
