@echo off
REM ===================================================================
REM  Run_Dump-PHD2Buttons.bat
REM
REM  Double-click front end for Dump-PHD2Buttons.ps1.
REM
REM  Prints every control in PHD2's main window with its exact caption,
REM  so the "Clear" buttons can be mapped in a language we have not
REM  covered yet. Read-only: it clicks nothing and never touches the
REM  mount.
REM
REM  Start PHD2 first, switch it to the language you want to map, and
REM  connect equipment - some controls do not exist until PHD2 has a
REM  camera.
REM
REM  Then send the file it writes into the logs folder. Send the FILE,
REM  not this window: the console mangles non-Latin scripts on some
REM  code pages, while the file is UTF-8 with a BOM.
REM ===================================================================

setlocal

set "SCRIPT=%~dp0Dump-PHD2Buttons.ps1"

echo.
echo  Dumping PHD2 main-window controls - %DATE% %TIME%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

set RC=%ERRORLEVEL%

echo.
echo Finished with exit code %RC%
echo.
pause
