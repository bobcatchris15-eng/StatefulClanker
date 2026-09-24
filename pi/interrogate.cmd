@echo off
setlocal
set "STATEFULCLANKER_PI_ROLE=interrogator"
call "%~dp0pi.cmd" %*
exit /b %ERRORLEVEL%
