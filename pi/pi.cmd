@echo off
setlocal
set "PI_CODING_AGENT_DIR=%LOCALAPPDATA%\StatefulClanker\pi"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-PiCatalog.ps1" >nul 2>&1
if exist "%~dp0runtime\node.exe" (
  "%~dp0runtime\node.exe" "%~dp0runtime\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js" --extension "%~dp0extensions\statefulclanker.ts" %*
  exit /b %ERRORLEVEL%
)
where pi >nul 2>&1
if %ERRORLEVEL% EQU 0 (
  pi --extension "%~dp0extensions\statefulclanker.ts" %*
  exit /b %ERRORLEVEL%
)
echo Bundled Pi runtime is missing. Reinstall StatefulClanker or install @earendil-works/pi-coding-agent. 1>&2
exit /b 127
