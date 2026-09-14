@echo off
REM Test provider that actually edits a file, so parallel commit and merge paths
REM can be exercised. %1 is the task id, %2 the file to write (relative to cwd).
REM Always votes PASS: the worker's own output is not verdict-parsed, and the same
REM command doubles as critic and validator.
if not "%~2"=="" (
  echo work from %~1 >> "%~2"
)
echo VERDICT: PASS
echo Writing provider completed the bounded task for %~1.
