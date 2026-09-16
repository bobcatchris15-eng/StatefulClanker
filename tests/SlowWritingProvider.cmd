@echo off
REM Slow test worker used to prove autofill replenishes vacant slots without exceeding maxConcurrent.
ping 127.0.0.1 -n 3 >nul
if not "%~2"=="" (
  echo work from %~1 >> "%~2"
)
echo VERDICT: PASS
echo Slow writing provider completed the bounded task for %~1.
