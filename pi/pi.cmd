@echo off
setlocal
set "PI_CODING_AGENT_DIR=%LOCALAPPDATA%\StatefulClanker\pi"
if "%STATEFULCLANKER_PI_ROLE%"=="" set "STATEFULCLANKER_PI_ROLE=operator"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-PiCatalog.ps1" >nul 2>&1

if /I "%STATEFULCLANKER_PI_ROLE%"=="interrogator" goto launch_interrogator

:launch_operator
if exist "%~dp0runtime\node.exe" (
  "%~dp0runtime\node.exe" "%~dp0runtime\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js" --extension "%~dp0extensions\statefulclanker.ts" --skill "%~dp0..\skills\statefulclanker\SKILL.md" %*
  exit /b %ERRORLEVEL%
)
where pi >nul 2>&1
if %ERRORLEVEL% EQU 0 (
  pi --extension "%~dp0extensions\statefulclanker.ts" --skill "%~dp0..\skills\statefulclanker\SKILL.md" %*
  exit /b %ERRORLEVEL%
)
goto missing_pi

:launch_interrogator
if exist "%~dp0runtime\node.exe" (
  "%~dp0runtime\node.exe" "%~dp0runtime\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js" --extension "%~dp0extensions\statefulclanker.ts" --skill "%~dp0..\skills\statefulclanker-interrogator\SKILL.md" --skill "%~dp0..\skills\statefulclanker-planner\SKILL.md" %*
  exit /b %ERRORLEVEL%
)
where pi >nul 2>&1
if %ERRORLEVEL% EQU 0 (
  pi --extension "%~dp0extensions\statefulclanker.ts" --skill "%~dp0..\skills\statefulclanker-interrogator\SKILL.md" --skill "%~dp0..\skills\statefulclanker-planner\SKILL.md" %*
  exit /b %ERRORLEVEL%
)

:missing_pi
echo Bundled Pi runtime is missing. Reinstall StatefulClanker or install @earendil-works/pi-coding-agent. 1>&2
exit /b 127
