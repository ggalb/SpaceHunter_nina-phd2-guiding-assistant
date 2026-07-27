<#
=====================================================================
 PHD2_GuidingAssistant.ps1
---------------------------------------------------------------------
 Purpose : Called by N.I.N.A. as an External Script, once per night,
           after the TPPA polar alignment routine and before imaging.

           1. Slew mount (via GS Server / ASCOM) to Dec 0, 5 deg west
              of the meridian, approaching from the south so the final
              move is northward and clears Dec backlash.
           2. Start PHD2 looping, auto-select a star, start guiding.
              NEVER calibrates - aborts if no calibration exists.
           3. Run the Guiding Assistant for a fixed duration.
           4. Apply every recommendation PHD2 offers.
           5. Stop capture, send the mount home, exit.

 Author  : Written for Georg's AtlasII / RC51 rig (EQ6-R + GSS + PHD2
           2.6.14 + N.I.N.A. 3.2)

 IMPORTANT: The Guiding Assistant is not exposed in PHD2's RPC API,
           so that portion is driven through Windows UI Automation.
           UIA addresses controls through the accessibility tree by
           name, not by screen coordinates, so display scaling and
           DPI are irrelevant. However a *disconnected* RDP session
           has no rendered desktop and UIA may fail - stay connected
           to the mini PC while this runs.

 EXIT CODES
   0   Success (or success with a warning logged)
   10  PHD2 not reachable / server not enabled
   11  PHD2 equipment not connected
   12  PHD2 not calibrated  -> script refuses to calibrate
   20  Mount (ASCOM/GSS) connect failed
   21  Mount slew failed or timed out
   22  Post-slew position sanity check failed
   23  Mount reports an invalid sidereal time or site location
   24  Mount driver lacks a capability the script requires
   30  No guide star found
   31  Guiding failed to settle
   40  Guiding Assistant window did not appear
   41  Guiding Assistant Start button never enabled
   42  Star lost / PHD2 error alert during the GA run
   43  No Apply buttons offered after the GA run
   44  Min-move values did not change after clicking Apply
   50  Stand-down (FindHome / Park) failed or timed out
   99  Unexpected error (see log)
=====================================================================
#>

[CmdletBinding()]
param(
    # ---- Timing -----------------------------------------------------
    [int]    $GASeconds            = 130,    # Guiding Assistant run length

    # ---- Target position --------------------------------------------
    [double] $TargetDec            = 0.0,    # degrees
    [double] $MeridianOffsetDeg    = 5.0,    # degrees WEST of meridian
    [double] $BacklashApproachDeg  = 1.0,    # approach from this far south

    # ---- PHD2 --------------------------------------------------------
    [string] $PhdHost              = '127.0.0.1',
    [int]    $PhdPort              = 4400,   # 4400 = instance 1
    [double] $SettlePixels         = 1.5,
    [int]    $SettleTime           = 10,
    [int]    $SettleTimeout        = 120,
    [int]    $MaxStarLost          = 8,      # tolerated StarLost events during GA

    # ---- Mount -------------------------------------------------------
    [string] $MountProgId          = 'ASCOM.GS.Sky.Telescope',
    [int]    $SlewTimeoutSec       = 180,
    [int]    $HomeTimeoutSec       = 300,
    [double] $PositionToleranceDeg = 3.0,    # post-slew sanity check

    # What to do with the mount when finished.
    #   Auto = FindHome if the driver supports it, else Park, else nothing
    [ValidateSet('Auto', 'Home', 'Park', 'None')]
    [string] $EndAction            = 'Auto',

    # ---- Behaviour ---------------------------------------------------
    [switch] $Simulate,                      # skip all mount movement
    [string] $LogDir               = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
# Version 1.0 deliberately: we probe optional properties on PHD2's JSON
# events (Error, Status, Type...) and StrictMode 2.0 would throw on the
# ones that are absent. 1.0 still catches uninitialised variables.
Set-StrictMode -Version 1.0

# =====================================================================
#  LOGGING
# =====================================================================

# Work out somewhere we can definitely write. When N.I.N.A. launches the
# script the working directory is not ours, and a silent failure here
# previously left us with no log at all - which made a failure
# undiagnosable. So: try the script folder, prove it is writable, and
# fall back to TEMP if not.
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($LogDir)) {
    try { $LogDir = Split-Path -Parent $MyInvocation.MyCommand.Definition } catch { }
}
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = (Get-Location).Path }

try {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $probe = Join-Path $LogDir ('.write_test_' + [guid]::NewGuid().ToString('N') + '.tmp')
    Set-Content -Path $probe -Value 'x' -ErrorAction Stop
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Host "WARNING: cannot write to '$LogDir' ($($_.Exception.Message)). Falling back to TEMP."
    $LogDir = $env:TEMP
}

$script:LogFile    = Join-Path $LogDir ("PHD2_GA_{0:yyyy-MM-dd_HHmmss}.log" -f (Get-Date))
$script:LogBroken  = $false

Write-Host "LOG FILE: $script:LogFile"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1,-5}  {2}" -f (Get-Date), $Level, $Message
    Write-Host $line
    if ($script:LogBroken) { return }
    try {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Say so once, on stdout, instead of failing silently forever.
        $script:LogBroken = $true
        Write-Host "WARNING: log file writes are failing: $($_.Exception.Message)"
    }
}

function Fail {
    param([int]$Code, [string]$Message)
    Write-Log $Message 'ERROR'
    throw (New-Object System.Exception ("EXIT$Code`: $Message"))
}

# Extract our exit code back out of the exception message
function Get-FailCode {
    param($ErrorRecord)
    if ($ErrorRecord.Exception.Message -match '^EXIT(\d+):') { return [int]$Matches[1] }
    return 99
}

# =====================================================================
#  PHD2  -  JSON-RPC over TCP, plus asynchronous event stream
# =====================================================================
#  PHD2 pushes event notification lines continuously on the same socket
#  it answers RPC calls on. Every line is a JSON object terminated by
#  CRLF. Responses carry an "id"; events carry an "Event" name. We pump
#  the socket, split on newlines, and route each line accordingly.

$script:PhdClient = $null
$script:PhdStream = $null
$script:PhdBuf    = ''
$script:PhdId     = 0
$script:PhdEvents = New-Object System.Collections.ArrayList

function Phd-Connect {
    Write-Log "Connecting to PHD2 at ${PhdHost}:${PhdPort} ..."
    try {
        $script:PhdClient = New-Object System.Net.Sockets.TcpClient
        $iar = $script:PhdClient.BeginConnect($PhdHost, $PhdPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(5000)) {
            throw "connection timed out"
        }
        $script:PhdClient.EndConnect($iar)
        $script:PhdStream = $script:PhdClient.GetStream()
    }
    catch {
        Fail 10 "Cannot reach PHD2 on ${PhdHost}:${PhdPort}. Is PHD2 running with Tools > Enable Server checked? ($($_.Exception.Message))"
    }
    Start-Sleep -Milliseconds 500
    Phd-Pump | Out-Null      # swallow the initial Version / AppState burst
    Write-Log "PHD2 connected."
}

function Phd-Disconnect {
    try { if ($script:PhdStream) { $script:PhdStream.Close() } } catch { }
    try { if ($script:PhdClient) { $script:PhdClient.Close() } } catch { }
    $script:PhdStream = $null
    $script:PhdClient = $null
}

# Drain whatever bytes are waiting and return complete lines
function Phd-Pump {
    $lines = New-Object System.Collections.ArrayList
    if (-not $script:PhdStream) { return $lines }
    try {
        while ($script:PhdStream.DataAvailable) {
            $buf = New-Object byte[] 8192
            $n = $script:PhdStream.Read($buf, 0, 8192)
            if ($n -le 0) { break }
            $script:PhdBuf += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        }
    } catch { }

    while ($script:PhdBuf.Contains("`n")) {
        $i    = $script:PhdBuf.IndexOf("`n")
        $line = $script:PhdBuf.Substring(0, $i).Trim()
        $script:PhdBuf = $script:PhdBuf.Substring($i + 1)
        if ($line) { [void]$lines.Add($line) }
    }
    return $lines
}

# Pump the socket, file away any events, return any RPC responses seen
function Phd-PumpAndRoute {
    $responses = New-Object System.Collections.ArrayList
    foreach ($line in (Phd-Pump)) {
        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ($obj.PSObject.Properties.Name -contains 'Event') {
            [void]$script:PhdEvents.Add($obj)
            if ($obj.Event -eq 'Alert') {
                Write-Log "PHD2 alert [$($obj.Type)]: $($obj.Msg)" 'WARN'
            }
        }
        elseif ($obj.PSObject.Properties.Name -contains 'id') {
            [void]$responses.Add($obj)
        }
    }
    return $responses
}

function Phd-Call {
    param(
        [string] $Method,
        $Params = $null,
        [int]    $TimeoutSec = 30
    )
    $script:PhdId++
    $id  = $script:PhdId
    $msg = @{ method = $Method; id = $id }
    if ($null -ne $Params) { $msg['params'] = $Params }

    $json  = ($msg | ConvertTo-Json -Depth 10 -Compress) + "`r`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $script:PhdStream.Write($bytes, 0, $bytes.Length)
    $script:PhdStream.Flush()

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        foreach ($r in (Phd-PumpAndRoute)) {
            if ($r.id -eq $id) {
                if ($r.PSObject.Properties.Name -contains 'error') {
                    throw "PHD2 '$Method' returned error: $($r.error.message)"
                }
                return $r.result
            }
        }
        Start-Sleep -Milliseconds 120
    }
    throw "PHD2 '$Method' timed out after ${TimeoutSec}s"
}

function Phd-ClearEvents { $script:PhdEvents.Clear() }

function Phd-TakeEvents {
    $copy = @($script:PhdEvents.ToArray())
    $script:PhdEvents.Clear()
    return $copy
}

# Find the guide algorithm's min-move parameter name on an axis.
# Different algorithms spell it slightly differently, so match loosely.
function Phd-GetMinMoveName {
    param([string]$Axis)
    try {
        $names = Phd-Call 'get_algo_param_names' @($Axis)
        foreach ($n in $names) { if ($n -replace '[^a-z]','' -match 'minmove') { return $n } }
    } catch { }
    return 'MinMove'
}

function Phd-GetMinMove {
    param([string]$Axis, [string]$Name)
    try { return [double](Phd-Call 'get_algo_param' @($Axis, $Name)) }
    catch { return $null }
}

# =====================================================================
#  MOUNT  -  ASCOM via GS Server
# =====================================================================

$script:Mount        = $null
$script:MountWeOpened = $false     # did *we* set Connected = true?
$script:Caps          = @{}        # capabilities, read AFTER connecting

# Read a driver property defensively. ASCOM drivers are entitled to throw
# PropertyNotImplementedException and several do.
function Get-MountProp {
    param([string]$Name, $Default = $null)
    try {
        $v = $script:Mount.$Name
        if ($null -eq $v) { return $Default }
        return $v
    } catch { return $Default }
}

# IMPORTANT: capabilities are read at runtime, after connecting to the
# actual mount - never from a lookup table. Established 2026-07-27: the
# iOptron driver reports CanFindHome = False while idle with no mount
# attached, but True once connected to a real CEM70EC. A static table
# would therefore be wrong.
function Mount-ReadCapabilities {
    foreach ($c in 'CanPark','CanUnpark','CanFindHome','CanSlew','CanSlewAsync',
                   'CanSetTracking','CanPulseGuide','CanSync') {
        $script:Caps[$c] = [bool](Get-MountProp $c $false)
    }

    $align = Get-MountProp 'AlignmentMode' $null
    $script:Caps['AlignmentMode'] = $align
    $script:Caps['IsAltAz']       = ($null -ne $align -and [int]$align -eq 0)

    $eq = Get-MountProp 'EquatorialSystem' $null
    $script:Caps['EquatorialSystem'] = $eq

    # SideOfPier is only useful if it is implemented AND not pierUnknown
    $pier = $null
    try { $pier = $script:Mount.SideOfPier } catch { }
    $script:Caps['HasPierSide'] = ($null -ne $pier -and [int]$pier -ge 0)

    Write-Log ("Driver capabilities: FindHome={0}  Park={1}  Unpark={2}  SlewAsync={3}  SetTracking={4}  PierSide={5}" -f `
               $script:Caps['CanFindHome'], $script:Caps['CanPark'], $script:Caps['CanUnpark'],
               $script:Caps['CanSlewAsync'], $script:Caps['CanSetTracking'], $script:Caps['HasPierSide'])

    $eqText = switch ($(if ($null -ne $eq) { [int]$eq } else { -1 })) {
        0 { 'Other' } 1 { 'Topocentric' } 2 { 'J2000' } 3 { 'B1950' } default { 'unknown' }
    }
    $alignText = switch ($(if ($null -ne $align) { [int]$align } else { -1 })) {
        0 { 'Alt-Az' } 1 { 'Polar' } 2 { 'German Polar (GEM)' } default { 'unknown' }
    }
    Write-Log "Alignment = $alignText.  Equatorial system = $eqText."

    # --- hard requirements -------------------------------------------
    if (-not ($script:Caps['CanSlew'] -or $script:Caps['CanSlewAsync'])) {
        Fail 24 "Driver reports it cannot slew to coordinates. This script cannot position the mount."
    }

    # --- advisories ---------------------------------------------------
    if ($script:Caps['IsAltAz']) {
        Write-Log ("Mount reports Alt-Az alignment. The 'Dec 0, {0} deg west of meridian' " +
                   "positioning assumes a German equatorial; results may not be meaningful." -f $MeridianOffsetDeg) 'WARN'
    }
    if ($null -ne $eq -and [int]$eq -eq 2) {
        Write-Log ("Driver uses J2000 coordinates while this script computes of-date coordinates " +
                   "from SiderealTime. Offset is ~0.4 deg in 2026 - negligible at a {0} deg " +
                   "meridian offset, but worth knowing." -f $MeridianOffsetDeg) 'WARN'
    }
    if (-not $script:Caps['HasPierSide']) {
        Write-Log "SideOfPier unavailable or pierUnknown - the post-slew check will test declination and hour angle only." 'WARN'
    }
}

# The ZWO driver returned SiderealTime = -1 when idle, and the iOptron
# returned site 0,0. Either would make the computed target meaningless
# and send the mount somewhere arbitrary. Check BEFORE moving anything.
function Mount-ValidateSite {
    $lst = Get-MountProp 'SiderealTime' $null
    if ($null -eq $lst) {
        Fail 23 "Mount does not report SiderealTime, which this script needs to compute the target."
    }
    $lst = [double]$lst
    if ($lst -lt 0 -or $lst -ge 24 -or [double]::IsNaN($lst)) {
        Fail 23 ("Mount reports SiderealTime = {0}, which is not a valid 0-24h value. " +
                 "Usually means the driver has no site configured or no mount attached." -f $lst)
    }

    $lat = Get-MountProp 'SiteLatitude'  $null
    $lon = Get-MountProp 'SiteLongitude' $null

    if ($null -eq $lat -or $null -eq $lon) {
        Write-Log "Mount does not report a site location - cannot sanity-check it." 'WARN'
    }
    else {
        $lat = [double]$lat; $lon = [double]$lon
        if ($lat -lt -90 -or $lat -gt 90 -or $lon -lt -180 -or $lon -gt 180) {
            Fail 23 ("Mount reports an impossible site: lat {0}, long {1}." -f $lat, $lon)
        }
        if ([Math]::Abs($lat) -lt 0.001 -and [Math]::Abs($lon) -lt 0.001) {
            Write-Log ("Mount reports site 0.000, 0.000 - the Gulf of Guinea. Almost certainly an " +
                       "unset default. Pointing will be wrong; check the driver's site settings.") 'WARN'
        }
        Write-Log ("Site: lat {0:N4}, long {1:N4}.  Local sidereal time {2:N4}h." -f $lat, $lon, $lst)
    }
}

function Mount-Connect {
    if ($Simulate) { Write-Log "[SIMULATE] skipping mount connect."; return }
    Write-Log "Connecting to mount '$MountProgId' ..."
    try {
        $script:Mount = New-Object -ComObject $MountProgId
        if (-not $script:Mount.Connected) {
            $script:Mount.Connected = $true
            $script:MountWeOpened = $true
            Start-Sleep -Seconds 2
        }
    }
    catch {
        Fail 20 "Could not connect to mount via '$MountProgId': $($_.Exception.Message)"
    }
    if (-not $script:Mount.Connected) { Fail 20 "Mount reports Connected = false." }
    Write-Log ("Mount connected. Name='{0}'  AtPark={1}  Tracking={2}" -f `
               $script:Mount.Name, $script:Mount.AtPark, $script:Mount.Tracking)

    Mount-ReadCapabilities
    Mount-ValidateSite
}

function Mount-Release {
    # NOTE: we deliberately do NOT set Connected = $false unless we were
    # the ones who opened it - N.I.N.A. holds its own connection through
    # GS Server and must not be dropped.
    try {
        if ($script:Mount -and $script:MountWeOpened) {
            $script:Mount.Connected = $false
            Write-Log "Released our own mount connection."
        }
    } catch { }
    try {
        if ($script:Mount) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:Mount)
        }
    } catch { }
    $script:Mount = $null
}

function Mount-WaitSlew {
    param([int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Start-Sleep -Milliseconds 800
    while ((Get-Date) -lt $deadline) {
        try { if (-not $script:Mount.Slewing) { Start-Sleep -Seconds 2; return $true } }
        catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# Compute an RA that sits $OffsetDeg degrees WEST of the meridian.
# Hour angle is positive to the west, so RA = LST - offset.
# Produces topocentric-of-date coordinates; Mount-ReadCapabilities warns
# if the driver expects J2000 instead.
function Get-TargetRA {
    param([double]$OffsetDeg)
    $lst = [double]$script:Mount.SiderealTime          # hours
    if ($lst -lt 0 -or $lst -ge 24) {
        Fail 23 ("SiderealTime became invalid ({0}) while computing the target." -f $lst)
    }
    $ra  = $lst - ($OffsetDeg / 15.0)
    while ($ra -lt 0)   { $ra += 24.0 }
    while ($ra -ge 24)  { $ra -= 24.0 }
    return $ra
}

# Use the async slew where available and fall back to the blocking call.
function Mount-StartSlew {
    param([double]$RA, [double]$Dec, [string]$Label)
    if ($script:Caps['CanSlewAsync']) {
        $script:Mount.SlewToCoordinatesAsync($RA, $Dec)
        return $true          # caller must poll Slewing
    }
    Write-Log "Driver has no async slew - using the blocking SlewToCoordinates for $Label."
    $script:Mount.SlewToCoordinates($RA, $Dec)
    return $false             # already finished on return
}

function Mount-SlewToCalibrationSpot {
    if ($Simulate) {
        Write-Log "[SIMULATE] skipping slew to Dec $TargetDec / ${MeridianOffsetDeg} deg west."
        return
    }

    if ($script:Mount.AtPark) {
        if (-not $script:Caps['CanUnpark']) {
            Fail 24 "Mount is parked and the driver reports it cannot unpark. Unpark it manually and rerun."
        }
        Write-Log "Mount is parked - unparking."
        $script:Mount.Unpark()
        Start-Sleep -Seconds 2
    }

    if (-not $script:Mount.Tracking) {
        if ($script:Caps['CanSetTracking']) {
            Write-Log "Enabling tracking."
            $script:Mount.Tracking = $true
            Start-Sleep -Seconds 2
        } else {
            Fail 24 "Tracking is off and the driver reports it cannot be set. The Guiding Assistant needs a tracking mount."
        }
    }

    # --- Leg 1: south of the target, to guarantee the final move is north
    $decSouth = $TargetDec - $BacklashApproachDeg
    $ra1 = Get-TargetRA $MeridianOffsetDeg
    Write-Log ("Slew 1/2 (backlash approach): RA {0:N4}h  Dec {1:N2}deg" -f $ra1, $decSouth)
    try {
        $async = Mount-StartSlew $ra1 $decSouth 'slew 1'
    } catch {
        Fail 21 "Slew 1 rejected by driver: $($_.Exception.Message)"
    }
    if ($async -and -not (Mount-WaitSlew $SlewTimeoutSec)) { Fail 21 "Slew 1 timed out after ${SlewTimeoutSec}s." }

    Start-Sleep -Seconds 2

    # --- Leg 2: northward onto the target. This is the backlash-clearing move.
    $ra2 = Get-TargetRA $MeridianOffsetDeg      # recomputed - LST has advanced
    Write-Log ("Slew 2/2 (north, clears Dec backlash): RA {0:N4}h  Dec {1:N2}deg" -f $ra2, $TargetDec)
    try {
        $async = Mount-StartSlew $ra2 $TargetDec 'slew 2'
    } catch {
        Fail 21 "Slew 2 rejected by driver: $($_.Exception.Message)"
    }
    if ($async -and -not (Mount-WaitSlew $SlewTimeoutSec)) { Fail 21 "Slew 2 timed out after ${SlewTimeoutSec}s." }

    # --- Sanity check. Should never fire; guards against a wildly wrong
    #     pointing model putting us on the wrong side of the meridian.
    $actualDec = [double]$script:Mount.Declination
    $actualRA  = [double]$script:Mount.RightAscension
    $lst       = [double]$script:Mount.SiderealTime
    $ha        = $lst - $actualRA
    while ($ha -lt -12) { $ha += 24 }
    while ($ha -gt  12) { $ha -= 24 }
    $haDeg = $ha * 15.0

    $pierSide = 'n/a'
    if ($script:Caps['HasPierSide']) {
        try {
            $pierSide = switch ([int]$script:Mount.SideOfPier) {
                0 { 'pierEast' } 1 { 'pierWest' } default { 'pierUnknown' }
            }
        } catch { $pierSide = 'n/a' }
    }

    Write-Log ("Position after slew: Dec {0:N2}deg  HA {1:N2}deg (+ = west)  SideOfPier={2}" -f `
               $actualDec, $haDeg, $pierSide)

    if ([Math]::Abs($actualDec - $TargetDec) -gt $PositionToleranceDeg) {
        Fail 22 ("Dec is {0:N2}deg, expected {1:N2}deg (tolerance {2}deg)." -f $actualDec, $TargetDec, $PositionToleranceDeg)
    }
    if ([Math]::Abs($haDeg - $MeridianOffsetDeg) -gt $PositionToleranceDeg) {
        Fail 22 ("Hour angle is {0:N2}deg, expected {1:N2}deg west (tolerance {2}deg)." -f $haDeg, $MeridianOffsetDeg, $PositionToleranceDeg)
    }
    Write-Log "Position sanity check passed."
}

# Stand the mount down at the end of the run. Honours -EndAction and the
# driver's actual capabilities. 'Auto' prefers FindHome, falls back to
# Park, and does nothing if the driver supports neither - which is a
# warning, not a failure, since the mount is still in a safe pointing
# position and N.I.N.A. may want to carry on with it.
function Mount-StandDown {
    if ($Simulate) { Write-Log "[SIMULATE] skipping end-of-run stand-down."; return $true }
    if (-not $script:Mount) { Write-Log "No mount handle - cannot stand down." 'WARN'; return $false }

    $action = $EndAction
    if ($action -eq 'Auto') {
        if     ($script:Caps['CanFindHome']) { $action = 'Home' }
        elseif ($script:Caps['CanPark'])     { $action = 'Park' }
        else                                 { $action = 'None' }
        Write-Log "EndAction 'Auto' resolved to '$action' from the driver's capabilities."
    }

    switch ($action) {

        'None' {
            Write-Log "EndAction = None - leaving the mount where it is." 'WARN'
            return $true
        }

        'Home' {
            if (-not $script:Caps['CanFindHome']) {
                Write-Log "EndAction = Home but the driver reports CanFindHome = false." 'ERROR'
                return $false
            }
            Write-Log "Sending mount home (FindHome) ..."
            try { $script:Mount.FindHome() }
            catch {
                Write-Log "FindHome threw: $($_.Exception.Message)" 'ERROR'
                return $false
            }
            # ASCOM allows FindHome to block or return immediately, so poll.
            $deadline = (Get-Date).AddSeconds($HomeTimeoutSec)
            while ((Get-Date) -lt $deadline) {
                try {
                    if ((-not $script:Mount.Slewing) -and $script:Mount.AtHome) {
                        Write-Log "Mount is at home. Tracking = $($script:Mount.Tracking)"
                        return $true
                    }
                } catch { }
                Start-Sleep -Seconds 2
            }
            Write-Log "FindHome did not report AtHome within ${HomeTimeoutSec}s." 'ERROR'
            return $false
        }

        'Park' {
            if (-not $script:Caps['CanPark']) {
                Write-Log "EndAction = Park but the driver reports CanPark = false." 'ERROR'
                return $false
            }
            Write-Log "Parking mount ..."
            try { $script:Mount.Park() }
            catch {
                Write-Log "Park threw: $($_.Exception.Message)" 'ERROR'
                return $false
            }
            $deadline = (Get-Date).AddSeconds($HomeTimeoutSec)
            while ((Get-Date) -lt $deadline) {
                try {
                    if ((-not $script:Mount.Slewing) -and $script:Mount.AtPark) {
                        Write-Log "Mount is parked. Tracking = $($script:Mount.Tracking)"
                        return $true
                    }
                } catch { }
                Start-Sleep -Seconds 2
            }
            Write-Log "Park did not report AtPark within ${HomeTimeoutSec}s." 'ERROR'
            return $false
        }
    }
    return $false
}

# =====================================================================
#  UI AUTOMATION  -  the Guiding Assistant dialog
# =====================================================================

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE   = [System.Windows.Automation.AutomationElement]
$CT   = [System.Windows.Automation.ControlType]
$SCOPE_CHILD = [System.Windows.Automation.TreeScope]::Children
$SCOPE_DESC  = [System.Windows.Automation.TreeScope]::Descendants

function UIA-FindTopWindow {
    param([string]$NameLike, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $kids = $AE::RootElement.FindAll($SCOPE_CHILD, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($w in $kids) {
                if ($w.Current.Name -like $NameLike) { return $w }
            }
        } catch { }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function UIA-FindDescendants {
    param($Root, $ControlType, [string]$Name = $null)
    $conds = New-Object System.Collections.ArrayList
    [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $ControlType)))
    if ($Name) {
        [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $Name)))
    }
    if ($conds.Count -eq 1) { $cond = $conds[0] }
    else { $cond = New-Object System.Windows.Automation.AndCondition($conds.ToArray([System.Windows.Automation.Condition])) }
    return $Root.FindAll($SCOPE_DESC, $cond)
}

function UIA-Invoke {
    param($Element)
    $p = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $p.Invoke()
}

# ---------------------------------------------------------------------
#  Native Win32 menu access.
#
#  Windows menus are HMENU objects, NOT child windows, so a UIA
#  TreeScope::Descendants search from the main window never reaches
#  them - which is exactly why the first version of this script failed
#  with exit 40. wxWidgets uses real Win32 menus underneath, so we walk
#  the HMENU directly, find the item captioned "Guiding Assistant...",
#  read its command ID and post WM_COMMAND to the window. This is the
#  same thing that happens when you click the item by hand.
# ---------------------------------------------------------------------

if (-not ('Native.Win32Menu' -as [type])) {
Add-Type -Namespace Native -Name Win32Menu -MemberDefinition @'
    [DllImport("user32.dll")]
    public static extern IntPtr GetMenu(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetMenuItemCount(IntPtr hMenu);

    [DllImport("user32.dll")]
    public static extern IntPtr GetSubMenu(IntPtr hMenu, int nPos);

    [DllImport("user32.dll")]
    public static extern uint GetMenuItemID(IntPtr hMenu, int nPos);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetMenuStringW(IntPtr hMenu, uint uIDItem,
        System.Text.StringBuilder lpString, int nMaxCount, uint uFlag);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr PostMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowExW(IntPtr hWndParent, IntPtr hWndChildAfter,
        string lpszClass, string lpszWindow);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
'@
}

$BM_CLICK    = 0x00F5
$BM_GETCHECK = 0x00F0
$WM_CLOSE    = 0x0010

$MF_BYPOSITION = 0x400
$WM_COMMAND    = 0x0111

# Recursively search an HMENU for a caption matching $Pattern.
# Returns the command ID, or 0 if not found. Also collects every caption
# seen into $Seen so we can log the menu contents when nothing matches.
function Find-MenuCommandId {
    param([IntPtr]$HMenu, [string]$Pattern, $Seen, [int]$Depth = 0)

    if ($HMenu -eq [IntPtr]::Zero -or $Depth -gt 3) { return 0 }
    $count = [Native.Win32Menu]::GetMenuItemCount($HMenu)

    for ($i = 0; $i -lt $count; $i++) {
        $sb = New-Object System.Text.StringBuilder 512
        [void][Native.Win32Menu]::GetMenuStringW($HMenu, [uint32]$i, $sb, 512, [uint32]$MF_BYPOSITION)
        # Strip the & mnemonic markers and any tab-separated accelerator
        $caption = ($sb.ToString() -replace '&', '') -replace "`t.*$", ''
        $caption = $caption.Trim()
        if ($caption) { [void]$Seen.Add($caption) }

        $sub = [Native.Win32Menu]::GetSubMenu($HMenu, $i)
        if ($sub -ne [IntPtr]::Zero) {
            $id = Find-MenuCommandId $sub $Pattern $Seen ($Depth + 1)
            if ($id -ne 0) { return $id }
            continue
        }

        if ($caption -like $Pattern) {
            return [int][Native.Win32Menu]::GetMenuItemID($HMenu, $i)
        }
    }
    return 0
}

function Get-PhdWindowHandle {
    param($UiaElement)
    # Prefer the handle UIA already knows about
    try {
        $h = [int]$UiaElement.Current.NativeWindowHandle
        if ($h -ne 0) { return [IntPtr]$h }
    } catch { }
    # Fall back to the process main window
    try {
        $p = Get-Process -Name 'phd2' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { return $p.MainWindowHandle }
    } catch { }
    return [IntPtr]::Zero
}

function Open-GuidingAssistant {
    $phd = UIA-FindTopWindow 'PHD2 Guiding*' 15
    if (-not $phd) { Fail 40 "Could not find the PHD2 main window." }
    Write-Log "PHD2 main window: '$($phd.Current.Name)'"

    $opened = $false

    # ---- Attempt 1: native Win32 menu command (most reliable) --------
    try {
        $hwnd = Get-PhdWindowHandle $phd
        if ($hwnd -eq [IntPtr]::Zero) {
            Write-Log "Could not obtain the PHD2 window handle." 'WARN'
        }
        else {
            $hMenu = [Native.Win32Menu]::GetMenu($hwnd)
            if ($hMenu -eq [IntPtr]::Zero) {
                Write-Log "PHD2 window reports no menu bar." 'WARN'
            }
            else {
                $seen = New-Object System.Collections.ArrayList
                $id = Find-MenuCommandId $hMenu '*Guiding*Assistant*' $seen
                if ($id -ne 0) {
                    Write-Log "Found 'Guiding Assistant' menu command id=$id - posting WM_COMMAND."
                    [void][Native.Win32Menu]::SetForegroundWindow($hwnd)
                    Start-Sleep -Milliseconds 200
                    [void][Native.Win32Menu]::PostMessageW($hwnd, [uint32]$WM_COMMAND, [IntPtr]$id, [IntPtr]::Zero)
                    $opened = $true
                }
                else {
                    Write-Log "No menu item matched '*Guiding*Assistant*'." 'WARN'
                    Write-Log ("Menu items seen: " + ($seen -join ' | ')) 'WARN'
                }
            }
        }
    } catch {
        Write-Log "Win32 menu navigation failed: $($_.Exception.Message)" 'WARN'
    }

    # ---- Attempt 2: UIA menu tree ------------------------------------
    if (-not $opened) {
        Write-Log "Trying UIA menu navigation." 'WARN'
        try {
            $tools = $null
            foreach ($mi in (UIA-FindDescendants $phd $CT::MenuItem)) {
                if ($mi.Current.Name -match '^Tools') { $tools = $mi; break }
            }
            if ($tools) {
                $ec = $tools.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
                $ec.Expand()
                Start-Sleep -Milliseconds 600
                foreach ($root in @($AE::RootElement, $phd)) {
                    foreach ($mi in (UIA-FindDescendants $root $CT::MenuItem)) {
                        if ($mi.Current.Name -like 'Guiding Assistant*') {
                            UIA-Invoke $mi
                            $opened = $true
                            break
                        }
                    }
                    if ($opened) { break }
                }
                if (-not $opened) { try { $ec.Collapse() } catch { } }
            } else {
                Write-Log "UIA found no 'Tools' menu item (expected - menus are not UIA children)." 'WARN'
            }
        } catch {
            Write-Log "UIA menu navigation failed: $($_.Exception.Message)" 'WARN'
        }
    }

    # ---- Attempt 3: keyboard ------------------------------------------
    if (-not $opened) {
        Write-Log "Falling back to keyboard menu navigation (Alt+T)." 'WARN'
        try {
            $wsh = New-Object -ComObject WScript.Shell
            $wsh.AppActivate($phd.Current.Name) | Out-Null
            Start-Sleep -Milliseconds 400
            $wsh.SendKeys('%t')
            Start-Sleep -Milliseconds 600
            $wsh.SendKeys('g')
            Start-Sleep -Milliseconds 600
        } catch {
            Write-Log "Keyboard fallback failed: $($_.Exception.Message)" 'WARN'
        }
    }

    $ga = Find-GAWindow 25
    if ($ga -eq [IntPtr]::Zero) {
        Log-WindowDiagnostics $phd
        Fail 40 "The Guiding Assistant window did not appear."
    }
    Write-Log "Guiding Assistant dialog is open."
    Log-GAControls $ga
    return $ga
}

# NOTE: PowerShell marshals $null to an EMPTY STRING for .NET string
# parameters. Passing $null to FindWindow's lpClassName therefore
# searches for a window whose class name is "" and finds nothing. This
# cost us two failed test runs. [NullString]::Value exists exactly for
# this and passes a real null pointer.
$NULLSTR = [NullString]::Value

# Dump everything we can see, so a detection failure is diagnosable in
# one pass rather than three.
function Log-WindowDiagnostics {
    param($PhdElement)

    Write-Log "--- window diagnostics ---" 'WARN'

    Write-Log "Win32 top-level windows:" 'WARN'
    try {
        $h = [IntPtr]::Zero
        for ($n = 0; $n -lt 300; $n++) {
            $h = [Native.Win32Menu]::FindWindowExW([IntPtr]::Zero, $h, $NULLSTR, $NULLSTR)
            if ($h -eq [IntPtr]::Zero) { break }
            if (-not [Native.Win32Menu]::IsWindowVisible($h)) { continue }
            $sb = New-Object System.Text.StringBuilder 512
            [void][Native.Win32Menu]::GetWindowTextW($h, $sb, 512)
            $t = $sb.ToString().Trim()
            if ($t) { Write-Log ("   [{0}] {1}" -f $h, $t) 'WARN' }
        }
    } catch {
        Write-Log "   Win32 enumeration failed: $($_.Exception.Message)" 'WARN'
    }

    Write-Log "UIA desktop children:" 'WARN'
    try {
        foreach ($w in $AE::RootElement.FindAll($SCOPE_CHILD, [System.Windows.Automation.Condition]::TrueCondition)) {
            $n = $w.Current.Name
            if ($n) { Write-Log ("   $n") 'WARN' }
        }
    } catch {
        Write-Log "   UIA desktop enumeration failed: $($_.Exception.Message)" 'WARN'
    }

    Write-Log "UIA windows nested under the PHD2 main window:" 'WARN'
    try {
        foreach ($w in (UIA-FindDescendants $PhdElement $CT::Window)) {
            $n = $w.Current.Name
            if ($n) { Write-Log ("   $n") 'WARN' }
        }
    } catch {
        Write-Log "   UIA nested enumeration failed: $($_.Exception.Message)" 'WARN'
    }

    Write-Log "--------------------------" 'WARN'
}

# Locate the GA dialog and return its WINDOW HANDLE (not a UIA element).
# UIA can see this window but not its children - wxWidgets dialogs expose
# poorly through the MSAA-to-UIA bridge - so everything downstream is
# done with plain Win32 calls instead.
function Find-GAWindow {
    param([int]$TimeoutSec = 25)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {

        # 1. exact-title lookup
        try {
            $h = [Native.Win32Menu]::FindWindowW($NULLSTR, 'Guiding Assistant')
            if ($h -ne [IntPtr]::Zero) {
                Write-Log ("Found GA window by exact title, handle [{0}]." -f $h)
                return $h
            }
        } catch { }

        # 2. scan top-level window titles
        try {
            $h = [IntPtr]::Zero
            for ($n = 0; $n -lt 300; $n++) {
                $h = [Native.Win32Menu]::FindWindowExW([IntPtr]::Zero, $h, $NULLSTR, $NULLSTR)
                if ($h -eq [IntPtr]::Zero) { break }
                $sb = New-Object System.Text.StringBuilder 512
                [void][Native.Win32Menu]::GetWindowTextW($h, $sb, 512)
                if ($sb.ToString() -like '*Guiding Assistant*') {
                    Write-Log ("Found GA window by title scan [{0}] '{1}'." -f $h, $sb.ToString())
                    return $h
                }
            }
        } catch { }

        Start-Sleep -Milliseconds 500
    }
    return [IntPtr]::Zero
}

# ---------------------------------------------------------------------
#  Win32 control access inside the GA dialog
# ---------------------------------------------------------------------

# Recursively enumerate child windows. wxWidgets nests controls inside
# panels and sizers, so a flat single-level scan is not enough.
function Get-ChildControls {
    param([IntPtr]$Parent, [int]$Depth = 0)

    $list = New-Object System.Collections.ArrayList
    if ($Depth -gt 5) { return $list }

    $h = [IntPtr]::Zero
    for ($i = 0; $i -lt 500; $i++) {
        $h = [Native.Win32Menu]::FindWindowExW($Parent, $h, $NULLSTR, $NULLSTR)
        if ($h -eq [IntPtr]::Zero) { break }

        $cls = New-Object System.Text.StringBuilder 256
        [void][Native.Win32Menu]::GetClassNameW($h, $cls, 256)
        $txt = New-Object System.Text.StringBuilder 512
        [void][Native.Win32Menu]::GetWindowTextW($h, $txt, 512)

        [void]$list.Add([pscustomobject]@{
            Handle  = $h
            Class   = $cls.ToString()
            Text    = ($txt.ToString() -replace '&', '').Trim()
            Enabled = [Native.Win32Menu]::IsWindowEnabled($h)
            Visible = [Native.Win32Menu]::IsWindowVisible($h)
        })

        foreach ($c in (Get-ChildControls $h ($Depth + 1))) { [void]$list.Add($c) }
    }
    return $list
}

function Get-GAControl {
    param([IntPtr]$GaHwnd, [string]$TextPattern)
    foreach ($c in (Get-ChildControls $GaHwnd)) {
        if ($c.Class -eq 'Button' -and $c.Text -like $TextPattern) { return $c }
    }
    return $null
}

# Find a top-level window by exact title. Returns IntPtr::Zero if absent.
function Find-TopWindowByTitle {
    param([string]$Title)
    try { return [Native.Win32Menu]::FindWindowW($NULLSTR, $Title) }
    catch { return [IntPtr]::Zero }
}

function Get-GAControls {
    param([IntPtr]$GaHwnd, [string]$TextPattern)
    $hits = New-Object System.Collections.ArrayList
    foreach ($c in (Get-ChildControls $GaHwnd)) {
        if ($c.Class -eq 'Button' -and $c.Text -like $TextPattern) { [void]$hits.Add($c) }
    }
    return $hits
}

function Click-Control {
    param($Control)
    [void][Native.Win32Menu]::PostMessageW($Control.Handle, [uint32]$BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Log-GAControls {
    param([IntPtr]$GaHwnd)
    Write-Log "--- controls inside the Guiding Assistant dialog ---" 'WARN'
    foreach ($c in (Get-ChildControls $GaHwnd)) {
        if ($c.Text -or $c.Class -eq 'Button') {
            Write-Log ("   {0,-16} enabled={1,-5} visible={2,-5} '{3}'" -f `
                       $c.Class, $c.Enabled, $c.Visible, $c.Text) 'WARN'
        }
    }
    Write-Log "---------------------------------------------------" 'WARN'
}

# Must run before Stop is clicked: with this box ticked, Stop begins a
# declination backlash run instead of finishing the session.
# wxCheckBox is a Win32 "Button" class control, so we find it by caption
# and read its state with BM_GETCHECK.
function Ensure-BacklashUnchecked {
    param([IntPtr]$GaHwnd)

    # NB: the pattern must be specific. '*Backlash*' also matches the
    # 'Show Backlash Graph' pushbutton, which appears EARLIER in the
    # enumeration and always reports BM_GETCHECK = 0 - so the script
    # cheerfully reported the box as unchecked while it was ticked.
    $cb = Get-GAControl $GaHwnd 'Measure*Backlash*'
    if (-not $cb) {
        Write-Log "Could not locate the backlash checkbox - continuing." 'WARN'
        return
    }

    $state = ([Native.Win32Menu]::SendMessageW($cb.Handle, [uint32]$BM_GETCHECK, [IntPtr]::Zero, [IntPtr]::Zero)).ToInt32()
    if ($state -ne 0) {
        Write-Log "'Measure Declination Backlash' was checked - unchecking it."
        Click-Control $cb
        Start-Sleep -Milliseconds 500
        $state = ([Native.Win32Menu]::SendMessageW($cb.Handle, [uint32]$BM_GETCHECK, [IntPtr]::Zero, [IntPtr]::Zero)).ToInt32()
        if ($state -ne 0) {
            Write-Log "Backlash checkbox is STILL checked after clicking it." 'WARN'
        } else {
            Write-Log "Backlash checkbox is now unchecked."
        }
    } else {
        Write-Log "'Measure Declination Backlash' is unchecked, as required."
    }
}

# PHD2 enforces a two-minute minimum sampling period. If Stop is clicked
# earlier it opens an 'Extended Sampling' window with a countdown and
# keeps measuring; recommendations - and the Apply buttons themselves -
# do not exist until that finishes. Wait it out.
function Wait-ForExtendedSampling {
    param([int]$TimeoutSec = 240)

    Start-Sleep -Seconds 2
    $h = Find-TopWindowByTitle 'Extended Sampling'
    if ($h -eq [IntPtr]::Zero) { return }

    Write-Log "PHD2 opened 'Extended Sampling' - it is topping up to its 2-minute minimum. Waiting."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Find-TopWindowByTitle 'Extended Sampling') -eq [IntPtr]::Zero) {
            Write-Log "Extended sampling finished."
            Start-Sleep -Seconds 2
            return
        }
        Start-Sleep -Seconds 2
    }
    Write-Log "Extended sampling did not finish within ${TimeoutSec}s - continuing anyway." 'WARN'
}

# =====================================================================
#  MAIN
# =====================================================================

$exitCode = 0
$gaWindow = [IntPtr]::Zero      # HWND of the Guiding Assistant dialog

try {
    Write-Log "==============================================================="
    Write-Log "PHD2 Guiding Assistant routine starting."
    Write-Log ("Parameters: GA={0}s  Dec={1}  MeridianOffset={2}degW  Approach={3}deg  Simulate={4}" -f `
               $GASeconds, $TargetDec, $MeridianOffsetDeg, $BacklashApproachDeg, [bool]$Simulate)
    Write-Log "Log file: $script:LogFile"
    Write-Log "==============================================================="

    # PHD2 will not offer any recommendations unless the baseline
    # sampling ran for at least two minutes. Below that the run
    # completes but the Recommendations panel stays empty, which this
    # script would report as exit 43.
    if ($GASeconds -lt 120) {
        Write-Log (("GASeconds is {0}. PHD2 needs at least 120s of sampling before it offers " +
                    "recommendations - expect exit 43 unless you are only testing that the " +
                    "GA window opens.") -f $GASeconds) 'WARN'
    }

    # ---------- 1. PHD2 pre-flight -----------------------------------
    Phd-Connect

    $state = Phd-Call 'get_app_state'
    Write-Log "PHD2 app state: $state"

    if (-not (Phd-Call 'get_connected')) {
        Fail 11 "PHD2 equipment is not connected."
    }

    if (-not (Phd-Call 'get_calibrated')) {
        Fail 12 "PHD2 has no calibration data. This script will not calibrate - run a calibration first."
    }
    Write-Log "PHD2 is calibrated - existing calibration will be reused."

    # Record min-move values so we can verify the Apply clicks later
    $raParam  = Phd-GetMinMoveName 'ra'
    $decParam = Phd-GetMinMoveName 'dec'
    $raBefore  = Phd-GetMinMove 'ra'  $raParam
    $decBefore = Phd-GetMinMove 'dec' $decParam
    Write-Log ("Min-move before: RA={0} ({1})  Dec={2} ({3})" -f $raBefore, $raParam, $decBefore, $decParam)

    # ---------- 2. Position the mount --------------------------------
    Mount-Connect
    Mount-SlewToCalibrationSpot

    # ---------- 3. Start guiding -------------------------------------
    Write-Log "Stopping any existing capture, then looping."
    Phd-Call 'stop_capture' | Out-Null
    Start-Sleep -Seconds 2
    Phd-Call 'loop' | Out-Null

    $exp = 2000
    try { $exp = [int](Phd-Call 'get_exposure') } catch { }
    Write-Log "Exposure is ${exp}ms - waiting for a couple of frames."
    Start-Sleep -Milliseconds ([Math]::Max(6000, $exp * 3))

    Write-Log "Auto-selecting a guide star."
    try {
        $lock = Phd-Call 'find_star'
        Write-Log ("Star selected at [{0}, {1}]" -f $lock[0], $lock[1])
    } catch {
        Fail 30 "find_star failed - no suitable guide star: $($_.Exception.Message)"
    }

    Write-Log "Starting guiding (recalibrate = false)."
    Phd-ClearEvents
    $settle = @{ pixels = $SettlePixels; time = $SettleTime; timeout = $SettleTimeout }
    Phd-Call 'guide' @{ settle = $settle; recalibrate = $false } | Out-Null

    # Wait for SettleDone
    $settled  = $false
    $deadline = (Get-Date).AddSeconds($SettleTimeout + 60)
    while ((Get-Date) -lt $deadline) {
        Phd-PumpAndRoute | Out-Null
        foreach ($e in (Phd-TakeEvents)) {
            if ($e.Event -eq 'SettleDone') {
                if ($e.Status -eq 0) {
                    Write-Log "Guiding settled."
                    $settled = $true
                } else {
                    Fail 31 "Guiding failed to settle: $($e.Error)"
                }
            }
            elseif ($e.Event -eq 'StarLost') {
                # Not fatal here - PHD2 recovers and settling continues -
                # but worth recording, since otherwise the only evidence
                # is PHD2 beeping and flashing the frame red.
                Write-Log "StarLost while settling: $($e.Status)" 'WARN'
            }
            elseif ($e.Event -eq 'StartCalibration') {
                # Should be impossible given the get_calibrated guard, but
                # if it ever happens we want to know loudly.
                Write-Log "PHD2 unexpectedly started calibrating!" 'WARN'
            }
        }
        if ($settled) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $settled) { Fail 31 "Timed out waiting for guiding to settle." }

    # ---------- 4. Guiding Assistant ---------------------------------
    $gaWindow = Open-GuidingAssistant
    Ensure-BacklashUnchecked $gaWindow

    # IMPORTANT: PHD2 auto-starts GA measurement if guiding is already
    # active when the dialog opens - which it always is here, because we
    # start guiding above. In that case 'Start' is DISABLED (measurement
    # underway) and 'Stop' is ENABLED. Waiting for 'Start' to become
    # enabled would hang forever. So: detect which state we're in.
    $measuring = $false
    $deadline  = (Get-Date).AddSeconds(60)

    while ((Get-Date) -lt $deadline) {
        $startBtn = Get-GAControl $gaWindow 'Start'
        $stopBtn  = Get-GAControl $gaWindow 'Stop'

        if ($stopBtn -and $stopBtn.Enabled) {
            Write-Log "GA auto-started measurement (guiding was already active)."
            $measuring = $true
            break
        }
        if ($startBtn -and $startBtn.Enabled) {
            Write-Log "GA is idle - clicking Start."
            Click-Control $startBtn
            $measuring = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $measuring) {
        Log-GAControls $gaWindow
        Fail 41 "The Guiding Assistant never entered the measuring state (neither Start nor Stop became enabled)."
    }

    # Time the full duration from here. If GA auto-started a few seconds
    # before we noticed, we simply sample slightly longer - harmless.
    Write-Log "Measuring for ${GASeconds}s."
    Phd-ClearEvents

    $starLost = 0
    $tEnd = (Get-Date).AddSeconds($GASeconds)
    while ((Get-Date) -lt $tEnd) {
        Phd-PumpAndRoute | Out-Null
        foreach ($e in (Phd-TakeEvents)) {
            switch ($e.Event) {
                'StarLost' {
                    $starLost++
                    Write-Log "StarLost during GA run (#$starLost): $($e.Status)" 'WARN'
                }
                'Alert' {
                    if ($e.Type -eq 'error') {
                        Fail 42 "PHD2 raised an error alert during the GA run: $($e.Msg)"
                    }
                }
            }
        }
        if ($starLost -gt $MaxStarLost) {
            Fail 42 "Guide star lost $starLost times during the GA run (limit $MaxStarLost)."
        }
        $remaining = [int]($tEnd - (Get-Date)).TotalSeconds
        if ($remaining % 30 -eq 0 -and $remaining -gt 0) {
            Write-Log "GA running - ${remaining}s remaining."
        }
        Start-Sleep -Seconds 1
    }

    # Re-check the backlash box immediately before Stop - if it is ticked,
    # Stop starts a declination backlash run instead of finishing.
    Ensure-BacklashUnchecked $gaWindow

    Write-Log "Clicking Stop."
    $stopBtn = Get-GAControl $gaWindow 'Stop'
    if ($stopBtn -and $stopBtn.Enabled) { Click-Control $stopBtn }
    else { Write-Log "'Stop' button not available - GA may have ended by itself." 'WARN' }

    # PHD2 may insist on more sampling before it will show results.
    Wait-ForExtendedSampling

    # ---------- 5. Apply the recommendations -------------------------
    # The Apply buttons are created only when the recommendations render,
    # so poll for them rather than assuming they already exist.
    $applyBtns = @()
    $deadline  = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $applyBtns = @(Get-GAControls $gaWindow 'Apply')
        if ($applyBtns.Count -gt 0) { break }
        Start-Sleep -Seconds 1
    }
    Write-Log ("Found {0} 'Apply' button(s)." -f $applyBtns.Count)

    $applied = 0
    foreach ($b in $applyBtns) {
        if ($b.Enabled) {
            Click-Control $b
            $applied++
            Start-Sleep -Milliseconds 600
        } else {
            Write-Log "An 'Apply' button was present but disabled - skipped." 'WARN'
        }
    }
    Write-Log "Clicked $applied 'Apply' button(s)."
    if ($applied -eq 0) {
        Log-GAControls $gaWindow
        Fail 43 "The Guiding Assistant offered no Apply buttons."
    }

    Start-Sleep -Seconds 1
    $raAfter  = Phd-GetMinMove 'ra'  $raParam
    $decAfter = Phd-GetMinMove 'dec' $decParam
    Write-Log ("Min-move after:  RA={0}  Dec={1}" -f $raAfter, $decAfter)

    # Verifying by "did the numbers change" is not sound on its own: if
    # PHD2 recommends the same values it recommended last time - which is
    # entirely normal, and guaranteed with the deterministic simulator -
    # nothing changes even though every click landed. So the primary
    # evidence is that PHD2 DISABLED the Apply buttons, which it does
    # once a recommendation has been applied. Unchanged values with the
    # buttons still live means the clicks really did miss.
    $stillEnabled = 0
    foreach ($b in (Get-GAControls $gaWindow 'Apply')) {
        if ($b.Enabled) { $stillEnabled++ }
    }

    if (($raAfter -eq $raBefore) -and ($decAfter -eq $decBefore)) {
        if ($stillEnabled -gt 0) {
            Log-GAControls $gaWindow
            Fail 44 ("Min-move values unchanged and {0} 'Apply' button(s) are still enabled - the clicks did not take." -f $stillEnabled)
        }
        Write-Log ("Min-move values are unchanged, but all 'Apply' buttons are now disabled, so the " +
                   "clicks landed. PHD2 simply recommended the same values it recommended last time.") 'WARN'
    }

    if ($applied -eq 1) {
        Write-Log "Only one recommendation was offered. This is normal when PHD2 judges one axis fine as-is." 'WARN'
    }

    # Close the GA dialog
    try {
        [void][Native.Win32Menu]::PostMessageW($gaWindow, [uint32]$WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
        Write-Log "Guiding Assistant closed."
    } catch {
        Write-Log "Could not close the GA dialog cleanly: $($_.Exception.Message)" 'WARN'
    }

    # ---------- 6. Stand down ----------------------------------------
    Write-Log "Stopping capture so N.I.N.A. starts guiding cleanly later tonight."
    try { Phd-Call 'stop_capture' | Out-Null } catch { Write-Log "stop_capture failed: $($_.Exception.Message)" 'WARN' }
    Start-Sleep -Seconds 2

    if (-not (Mount-StandDown)) { Fail 50 "Mount failed to reach its end-of-run position." }

    Write-Log "Routine completed successfully."
    $exitCode = 0
}
catch {
    $exitCode = Get-FailCode $_
    Write-Log "FAILED (exit $exitCode): $($_.Exception.Message)" 'ERROR'
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace 'ERROR' }

    # Best-effort safe shutdown: stop guiding, park the rig at home.
    try {
        if ($script:PhdStream) {
            Write-Log "Recovery: stopping PHD2 capture."
            Phd-Call 'stop_capture' -TimeoutSec 15 | Out-Null
        }
    } catch { Write-Log "Recovery stop_capture failed: $($_.Exception.Message)" 'WARN' }

    try {
        if ($gaWindow -and $gaWindow -ne [IntPtr]::Zero) {
            [void][Native.Win32Menu]::PostMessageW($gaWindow, [uint32]$WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
        }
    } catch { }

    try {
        if (-not $script:Mount -and -not $Simulate) { Mount-Connect }
        Write-Log "Recovery: standing the mount down."
        Mount-StandDown | Out-Null
    } catch { Write-Log "Recovery stand-down failed: $($_.Exception.Message)" 'ERROR' }
}
finally {
    Phd-Disconnect
    Mount-Release
    Write-Log "Exit code $exitCode. Log: $script:LogFile"
}

exit $exitCode
