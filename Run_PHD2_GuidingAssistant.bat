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
REM  ALL console output is appended to NINA_console.txt beside this
REM  file. N.I.N.A. runs the script without a console we can read, so
REM  that transcript is the only record of anything printed before the
REM  script's own log file gets going - including the reason the log
REM  file itself might be missing.
REM ===================================================================

setlocal

set "SCRIPT=%~dp0PHD2_GuidingAssistant.ps1"
set "CONSOLE=%~dp0NINA_console.txt"

>>"%CONSOLE%" echo.
>>"%CONSOLE%" echo ==========================================================
>>"%CONSOLE%" echo  Run started %DATE% %TIME%
>>"%CONSOLE%" echo ==========================================================

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT%" -GASeconds 130 >>"%CONSOLE%" 2>&1

set RC=%ERRORLEVEL%

>>"%CONSOLE%" echo ----------------------------------------------------------
>>"%CONSOLE%" echo  Finished %DATE% %TIME%   exit code %RC%
>>"%CONSOLE%" echo ----------------------------------------------------------

echo Script finished with exit code %RC%
exit /b %RC%
