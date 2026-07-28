@echo off
REM ===================================================================
REM  Run_PHD2_GuidingAssistant.bat
REM  Called by the N.I.N.A. "External Script" instruction.
REM
REM  Place this file and PHD2_GuidingAssistant.ps1 in the SAME folder,
REM  then point the N.I.N.A. External Script instruction at this .bat.
REM
REM  The PowerShell exit code is passed straight back to N.I.N.A., so a
REM  non-zero exit fails the sequence instruction (and will fire the
REM  "Failures to Pushover" global trigger).
REM
REM  OUTPUT
REM    - Progress prints to the console window N.I.N.A. opens, so you
REM      can watch a run happen.
REM    - The full run record is the script's own log, written to
REM      logs\PHD2_GA_<timestamp>.log. Every line shown on screen is in
REM      there too.
REM    - Only stderr is captured to logs\stderr.txt, as a safety net for
REM      a catastrophic failure that kills the script before its log
REM      exists - the console window closes too fast to read in that
REM      case.
REM ===================================================================

setlocal

set "SCRIPT=%~dp0PHD2_GuidingAssistant.ps1"
set "LOGDIR=%~dp0logs"
set "ERRLOG=%LOGDIR%\stderr.txt"

if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo.
echo  Starting PHD2 Guiding Assistant routine - %DATE% %TIME%
echo.

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT%" -GASeconds 130 2>>"%ERRLOG%"

set RC=%ERRORLEVEL%

echo.
echo Script finished with exit code %RC%
exit /b %RC%
