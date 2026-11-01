@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required. Install it, then reopen this terminal:
  echo https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -File "%~dp0scripts\Login.ps1" %*
exit /b %errorlevel%
