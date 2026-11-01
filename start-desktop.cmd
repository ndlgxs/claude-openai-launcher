@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required. Install it, then run this file again.
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -File "%~dp0scripts\Start-Desktop.ps1" %*
exit /b %errorlevel%
