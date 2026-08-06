@echo off
REM ===================================================================
REM  Run_PHD2_GuidingAssistant.bat
REM  Called by the N.I.N.A. "External Script" instruction.
REM
REM  Place this file and PHD2_GuidingAssistant.ps1 in the SAME folder,
REM  then point the N.I.N.A. External Script instruction at this .bat.
REM
REM  ------------------------------------------------------------------
REM   SETTINGS - edit the three values below to change behaviour.
REM   See "Changing the defaults" in README.md for what they mean and
REM   for one-line commands that edit them for you.
REM  ------------------------------------------------------------------
REM
REM  The PowerShell exit code is passed straight back to N.I.N.A., so a
REM  non-zero exit fails the sequence instruction (and will fire the
REM  "Failures to Pushover" global trigger).
REM
REM  OUTPUT
REM    - Progress prints to the console window N.I.N.A. opens.
REM    - The full run record is logs\PHD2_GA_<timestamp>.log.
REM    - Only stderr goes to logs\stderr.txt, as a safety net for a
REM      failure that kills the script before its own log exists.
REM ===================================================================

setlocal

REM --- SETTINGS ------------------------------------------------------

REM Guiding Assistant sampling time, seconds. Must be > 120: PHD2
REM enforces a two-minute minimum and will top up shorter runs itself.
set "GASECONDS=130"

REM Target declination in degrees. 0 = celestial equator (recommended).
set "TARGETDEC=0"

REM Degrees from the meridian. POSITIVE = west, NEGATIVE = east.
set "MERIDIANOFFSET=5"

REM  ASCOM mount driver ProgID.
REM
REM  LEAVE THIS EMPTY to use the script's own default,
REM  ASCOM.GS.Sky.Telescope (GS Server). Set it if you use a different
REM  driver - there is no need to edit the PowerShell.
REM
REM    EQMOD.Telescope                 EQMOD
REM    ASCOM.iOptron2017.Telescope     iOptron
REM    ASCOM.ASIMount.Telescope        ZWO
REM    ASCOM.Simulator.Telescope       ASCOM Telescope Simulator
REM
REM  List the drivers registered on this machine with:
REM    $p = New-Object -ComObject ASCOM.Utilities.Profile
REM    $p.RegisteredDevices('Telescope')
set "MOUNTPROGID="

REM --- end of settings ----------------------------------------------

set "SCRIPT=%~dp0PHD2_GuidingAssistant.ps1"
set "LOGDIR=%~dp0logs"
set "ERRLOG=%LOGDIR%\stderr.txt"

if not exist "%LOGDIR%" mkdir "%LOGDIR%"

REM An empty setting must not be passed at all - -MountProgId "" would
REM look like a configured driver that cannot be opened.
set "EXTRAARGS="
if not "%MOUNTPROGID%"=="" set EXTRAARGS=%EXTRAARGS% -MountProgId "%MOUNTPROGID%"

echo.
echo  Starting PHD2 Guiding Assistant routine - %DATE% %TIME%
echo   GA time %GASECONDS%s, Dec %TARGETDEC%, meridian offset %MERIDIANOFFSET% deg
if "%EXTRAARGS%"=="" echo   Mount: script default (GS Server)
if not "%EXTRAARGS%"=="" echo   Mount:%EXTRAARGS%
echo.

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT%" -GASeconds %GASECONDS% -TargetDec %TARGETDEC% -MeridianOffsetDeg %MERIDIANOFFSET%%EXTRAARGS% 2>>"%ERRLOG%"

set RC=%ERRORLEVEL%

echo.
echo Script finished with exit code %RC%
exit /b %RC%
