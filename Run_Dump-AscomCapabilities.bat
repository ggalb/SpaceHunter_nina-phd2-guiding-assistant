@echo off
REM ===================================================================
REM  Run_Dump-AscomCapabilities.bat
REM
REM  Double-click this to profile your mount's ASCOM driver.
REM  Keep it in the same folder as Dump-AscomCapabilities.ps1.
REM
REM  READ ONLY - it never slews, parks, homes, changes any setting, or
REM  disconnects your mount. Safe to run while the mount is connected
REM  and in use by N.I.N.A., SGP or anything else.
REM
REM  Everything printed is also saved to ascom_dump.txt beside this
REM  file, so you can just send that back.
REM ===================================================================

setlocal

set "SCRIPT=%~dp0Dump-AscomCapabilities.ps1"
set "OUT=%~dp0ascom_dump.txt"

if not exist "%SCRIPT%" (
    echo.
    echo  ERROR: Dump-AscomCapabilities.ps1 was not found next to this file.
    echo  Both files must be in the same folder.
    echo.
    pause
    exit /b 1
)

echo.
echo  ============================================================
echo   ASCOM mount capability dump
echo  ============================================================
echo.
echo   This only READS from your mount driver.
echo   Nothing will move. Nothing will be changed or disconnected.
echo.
echo   Please make sure your mount is POWERED ON and CONNECTED -
echo   drivers report different capabilities when they are idle.
echo.
echo   A driver chooser will open in a moment. Pick your mount.
echo.
pause

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%SCRIPT%' | Tee-Object -FilePath '%OUT%'"

echo.
echo  ============================================================
echo   Saved to: %OUT%
echo   Please send that file back. Thank you!
echo  ============================================================
echo.
pause
