@echo off
REM Test provider that always votes FAIL, for exercising the review-failure path:
REM project hold, remediation task, and refusal of further dispatch.
echo VERDICT: FAIL
echo The project does not build; tests/Smoke.ps1 reports 3 failing assertions.
