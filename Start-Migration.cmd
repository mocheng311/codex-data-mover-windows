@echo off
setlocal
title Codex Data Mover - Windows
if /I "%OS%" NEQ "Windows_NT" (
  echo This tool requires Windows.
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -File "%~dp0Invoke-Migration.ps1" %*
set "migrationExit=%errorlevel%"
echo.
if "%migrationExit%"=="0" (
  echo Command completed. Plan or Status does not mean data was migrated.
) else (
  echo NOT COMPLETED. Keep all data copies and inspect Status.
)
pause
exit /b %migrationExit%
