@echo off
REM ===================================================================
REM  TEST_Simulate_PHD2_GuidingAssistant.bat
REM
REM  DRY RUN ONLY. -Simulate skips every mount operation: no connect,
REM  no slew, no FindHome. Nothing moves.
REM
REM  Use this for daytime testing of the PHD2 socket path and the
REM  Guiding Assistant automation, with PHD2 on its Simulator profile.
REM
REM  Do NOT point the N.I.N.A. sequence at this file - use
REM  Run_PHD2_GuidingAssistant.bat for that.
REM ===================================================================

REM  Optional argument: GA duration in seconds. Defaults to 130.
REM  PHD2 offers NO recommendations below 120s, so a shorter run will
REM  end in exit 43 even when everything else worked. Use a short value
REM  only when you just want to check that the GA window opens:
REM      TEST_Simulate_PHD2_GuidingAssistant.bat 30

setlocal

set "SCRIPT=%~dp0PHD2_GuidingAssistant.ps1"

set "GASEC=%~1"
if "%GASEC%"=="" set "GASEC=130"

echo.
echo  *** SIMULATE MODE - the mount will NOT be touched ***
echo  *** Guiding Assistant duration: %GASEC% seconds ***
echo.

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT%" -Simulate -GASeconds %GASEC%

set RC=%ERRORLEVEL%
echo.
echo Script finished with exit code %RC%
pause
exit /b %RC%
