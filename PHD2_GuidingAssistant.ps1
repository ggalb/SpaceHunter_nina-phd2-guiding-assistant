<#
=====================================================================
 PHD2_GuidingAssistant.ps1
---------------------------------------------------------------------
 Why run the Guiding Assistant at all?
           With guide output switched off, PHD2 watches an unguided star
           and measures what the sky and the mount are actually doing
           tonight: high-frequency star motion (the seeing), drift in RA
           and Dec, polar alignment error, and optionally declination
           backlash.

           The most useful product is the recommended MINIMUM MOVE for
           each axis - the threshold below which the guider should not
           react at all. Set it too low and the guider chases seeing,
           issuing corrections for motion that has already reversed and
           making the tracking worse than leaving it alone. Set it too
           high and real drift goes uncorrected.

           The right value depends on the seeing, which changes from
           night to night and even through a single night. That is the
           argument for measuring it each session rather than setting it
           once and forgetting it - and, since the measurement is
           mechanical and takes minutes, for automating it.

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

 IMPORTANT: The Guiding Assistant is not exposed in PHD2's RPC API, so
           that portion is driven through the Windows API - almost
           entirely window messages (FindWindow, PostMessage, BM_CLICK
           and friends), which address controls by name and handle
           rather than by screen position. Display scaling and DPI are
           therefore irrelevant.

           UNATTENDED OPERATION: tested and working with the desktop
           session DISCONNECTED. On 2026-07-31 a full run completed
           with exit 0 while the RDP client was closed for the entire
           duration - including the one remaining UI Automation call,
           which locates the PHD2 main window. Nothing here needs a
           rendered display, so a locked or headless console session
           is fine too. An earlier version of this comment warned
           otherwise; that warning was precautionary and untested, and
           it was wrong.

           The one exception is the SendKeys fallback for opening the
           Tools menu, which does need an input desktop. It is the
           third fallback and only runs if the Win32 and UIA paths have
           both already failed.

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

    # How long to wait after Stop for the recommendations to appear.
    # Generous on purpose: PHD2 may still be topping the sample up to its
    # two-minute minimum, or running a backlash measurement.
    [int]    $ApplyWaitSec         = 300,

    # ---- Mount -------------------------------------------------------
    [string] $MountProgId          = 'ASCOM.GS.Sky.Telescope',
    [int]    $SlewTimeoutSec       = 180,
    [int]    $HomeTimeoutSec       = 300,
    [double] $PositionToleranceDeg = 3.0,    # post-slew sanity check

    # What to do with the mount when finished.
    #   Auto = FindHome if the driver supports it, else Park, else nothing
    [ValidateSet('Auto', 'Home', 'Park', 'None')]
    [string] $EndAction            = 'Auto',

    # ---- PHD2 user-interface strings ---------------------------------
    # The Guiding Assistant is driven through its GUI, so these captions
    # matter. PHD2's translations are patchy - in German the 'Tools' menu
    # itself stays English while the item becomes 'Nachfuehrassistent'.
    #
    # NOTE: patterns are deliberately ASCII-only, using wildcards where a
    # word contains an accented character. Windows PowerShell 5.1 reads a
    # UTF-8 file without a BOM as ANSI, so a literal umlaut here could be
    # mangled and never match. '*Nachf*hrassistent*' sidesteps that.
    #
    # If your language is missing, add it here - and please report it so
    # it can be added for everyone.
    # BE SPECIFIC. Several languages leave 'Calibration Assistant...'
    # untranslated, so a loose '*Assistant*' would match that instead and
    # open the wrong dialog. Each pattern below names both words.
    [string[]] $GAMenuPatterns = @(
        '*Guiding*Assistant*',      # English
        '*Nachf*hrassistent*',      # German  - Nachfuehrassistent
        '*Assistant*Guidage*',      # French  - Assistant de Guidage
        '*Asistente*Guiado*',       # Spanish - Asistente de Guiado
        '*Assistente*Guida*',       # Italian  - Assistente di guida
        '*Assistente*guiagem*'      # Portuguese - Assistente de guiagem
    ),

    # Last-resort way into the dialog when no caption matches. Windows
    # menu command IDs are assigned at build time and do NOT vary by
    # locale - 216 was observed identically in English, German, French
    # and Spanish builds of PHD2 2.6.14. It MAY change between PHD2
    # versions, so it is only used after caption matching has failed,
    # and the result is verified by checking a window actually appeared.
    # Set to 0 to disable.
    [int] $GAMenuCommandId = 216,

    # NB: PHD2 is not internally consistent - in German the MENU item is
    # 'Nachfuehrassistent' but the WINDOW is titled 'Guiding-Assistent'.
    [string[]] $GAWindowTitles = @(
        'Guiding Assistant',        # English
        'Assistant de Guidage',     # French
        'Guiding-Assistent',        # German
        'Asistente de Guiado',      # Spanish
        'Assistente di guida',      # Italian
        'Assistente de guiagem'     # Portuguese
    ),

    # Buttons inside the dialog. Wildcards stand in for accented letters:
    # 'D*marrer' matches Demarrer, 'Arr*ter' matches Arreter.
    [string[]] $GAStartPatterns = @(
        'Start',                    # English
        'Starten',                  # German
        'D*marrer',                 # French  - Demarrer
        'Iniciar',                  # Spanish / Portuguese
        'Inizia'                    # Italian
    ),

    [string[]] $GAStopPatterns = @(
        'Stop',                     # English, and German leaves it as-is
        'Arr*ter',                  # French  - Arreter
        'Parar',                    # Spanish / Portuguese
        'Ferma'                     # Italian
    ),

    [string[]] $GAApplyPatterns = @(
        'Apply',                    # English
        'Anwenden',                 # German  - confirmed 2026-07-31
        'Aplicar',                  # Spanish - confirmed 2026-07-31
        'Applica',                  # Italian - confirmed 2026-07-31
        'Appliquer'                 # French  - candidate; French may also use 'Apply'
    ),

    # Must be specific: French also has 'Montrer le Graphique du Jeu',
    # which contains 'Jeu' but is a pushbutton, not the checkbox.
    # Each is specific enough not to match the 'Show Backlash Graph'
    # pushbutton, which also contains the word Backlash in several
    # languages.
    [string[]] $GABacklashPatterns = @(
        'Measure*Backlash*',        # English
        'Messung*Backlash*',        # German  - Messung Backlash der Deklination
        'Medida*Backlash*',         # Spanish - Medida del Backlash de Declinacion
        'Misurazione*backlash*',    # Italian - Misurazione del backlash in declinazione
        'Medir*folga*',             # Portuguese - Medir folga de declinacao
                                    #   note: no form of 'backlash' appears at all
        'Mesurer*Jeu*'              # French  - Mesurer le Jeu de Declinaison
    ),

    # ---- Behaviour ---------------------------------------------------
    [switch] $Simulate,                      # skip all mount movement

    # Where to write the run log. Defaults to a 'logs' subfolder beside
    # the script, created if it does not exist.
    [string] $LogDir               = ''
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
if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        try { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
    $LogDir = Join-Path $scriptDir 'logs'
}

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

    # On connect PHD2 sends a burst of events beginning with 'Version'.
    # Record it: the Guiding Assistant is driven through its GUI, whose
    # window title and button captions are not an API and could change
    # between releases. Knowing which PHD2 a run succeeded against is
    # what makes an upgrade-related breakage quick to diagnose.
    $phdVersion = $null
    foreach ($line in (Phd-Pump)) {
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ($obj.PSObject.Properties.Name -contains 'Event' -and $obj.Event -eq 'Version') {
            $phdVersion = $obj
        }
    }

    if ($phdVersion) {
        $sub = ''
        try { if ($phdVersion.PHDSubver) { $sub = $phdVersion.PHDSubver } } catch { }
        Write-Log ("PHD2 connected.  Version {0}{1}   (RPC message protocol v{2})" -f `
                   $phdVersion.PHDVersion, $sub, $phdVersion.MsgVersion)
    }
    else {
        Write-Log "PHD2 connected. (No Version event seen - continuing.)" 'WARN'
    }
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
    # We never set Connected = $false.
    #
    # Evidence from 2026-07-27: GS Server appears to share ONE Connected
    # state across all ASCOM clients rather than giving each its own. Run
    # 1 that day took 8s to connect and reported releasing its own
    # handle; run 2, with N.I.N.A. connected, found Connected already
    # true and left it alone. If the state is shared, setting it false
    # would tear down N.I.N.A.'s link mid-sequence.
    #
    # Releasing the COM object is sufficient: our client goes away when
    # the process exits moments later. Leaving the driver connected costs
    # nothing and removes the only way this script could drop N.I.N.A.
    try {
        if ($script:Mount -and $script:MountWeOpened) {
            Write-Log "Leaving the mount connected (we opened it, but the driver state may be shared with N.I.N.A.)."
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

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);
'@
}

$GWL_STYLE = -16
# Button style bits. The low nibble of a BUTTON's style says what kind
# of button it is - and unlike its caption, that is not translated.
$BS_TYPEMASK      = 0x0F
$BS_CHECKBOX      = 0x02
$BS_AUTOCHECKBOX  = 0x03
$BS_3STATE        = 0x05
$BS_AUTO3STATE    = 0x06

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

    # Snapshot the visible top-level windows BEFORE we invoke anything.
    # If no known title matches afterwards, the window that appeared in
    # the meantime is the dialog - whatever language it is in.
    $windowsBefore = Get-TopLevelWindowMap

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
                $id = 0
                $matched = ''
                foreach ($pat in $GAMenuPatterns) {
                    $seen.Clear()
                    $id = Find-MenuCommandId $hMenu $pat $seen
                    if ($id -ne 0) { $matched = $pat; break }
                }
                if ($id -ne 0) {
                    Write-Log "Found the Guiding Assistant menu item via pattern '$matched', command id=$id - posting WM_COMMAND."
                    [void][Native.Win32Menu]::SetForegroundWindow($hwnd)
                    Start-Sleep -Milliseconds 200
                    [void][Native.Win32Menu]::PostMessageW($hwnd, [uint32]$WM_COMMAND, [IntPtr]$id, [IntPtr]::Zero)
                    $opened = $true
                }
                else {
                    Write-Log ("No menu item matched any of: " + ($GAMenuPatterns -join ' , ')) 'WARN'
                    Write-Log ("Menu items seen: " + ($seen -join ' | ')) 'WARN'
                    Write-Log ("If PHD2 is not in English, find the Guiding Assistant entry in that " +
                               "list and pass it via -GAMenuPatterns (ASCII wildcards only, e.g. " +
                               "'*Nachf*hrassistent*').") 'WARN'

                    # Language-independent last resort: the command ID.
                    if ($GAMenuCommandId -gt 0) {
                        Write-Log ("Trying the known menu command id {0} instead - menu IDs do not vary by language." -f $GAMenuCommandId) 'WARN'
                        [void][Native.Win32Menu]::SetForegroundWindow($hwnd)
                        Start-Sleep -Milliseconds 200
                        [void][Native.Win32Menu]::PostMessageW($hwnd, [uint32]$WM_COMMAND, [IntPtr]$GAMenuCommandId, [IntPtr]::Zero)
                        $opened = $true
                    }
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

    $ga = Find-GAWindow 25 $windowsBefore
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
    param(
        [int]$TimeoutSec = 25,
        $WindowsBefore = $null      # snapshot taken before the menu command
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {

        # 1. exact-title lookup, for each known translation
        foreach ($title in $GAWindowTitles) {
            try {
                $h = [Native.Win32Menu]::FindWindowW($NULLSTR, $title)
                if ($h -ne [IntPtr]::Zero) {
                    Write-Log ("Found GA window by exact title '{0}', handle [{1}]." -f $title, $h)
                    return $h
                }
            } catch { }
        }

        # 2. partial title scan, for each known translation
        try {
            $h = [IntPtr]::Zero
            for ($n = 0; $n -lt 400; $n++) {
                $h = [Native.Win32Menu]::FindWindowExW([IntPtr]::Zero, $h, $NULLSTR, $NULLSTR)
                if ($h -eq [IntPtr]::Zero) { break }
                $sb = New-Object System.Text.StringBuilder 512
                [void][Native.Win32Menu]::GetWindowTextW($h, $sb, 512)
                $t = $sb.ToString()
                foreach ($title in $GAWindowTitles) {
                    if ($t -like ('*' + $title + '*')) {
                        Write-Log ("Found GA window by title scan [{0}] '{1}'." -f $h, $t)
                        return $h
                    }
                }
            }
        } catch { }

        # 3. LANGUAGE-INDEPENDENT: whatever window just appeared.
        #    We snapshotted the visible top-level windows before invoking
        #    the menu item, so a newly-arrived window is almost certainly
        #    the dialog - whatever it happens to be called. This is what
        #    lets the script work in a language nobody has mapped yet.
        if ($WindowsBefore) {
            $now = Get-TopLevelWindowMap
            foreach ($key in $now.Keys) {
                if (-not $WindowsBefore.ContainsKey($key)) {
                    $title = $now[$key]
                    # Ignore the PHD2 main window itself if it re-registers
                    if ($title -like 'PHD2*') { continue }
                    Write-Log ("Found a NEW window after the menu command: '{0}'" -f $title)
                    Write-Log ("If that is the Guiding Assistant in your language, add it to " +
                               "-GAWindowTitles so future runs match it directly.") 'WARN'
                    return [IntPtr][int]$key
                }
            }
        }

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

        $style = 0
        try { $style = [Native.Win32Menu]::GetWindowLongW($h, $GWL_STYLE) } catch { }
        $btnType = $style -band $BS_TYPEMASK
        $isCheck = ($cls.ToString() -eq 'Button') -and
                   ($btnType -eq $BS_CHECKBOX -or $btnType -eq $BS_AUTOCHECKBOX -or
                    $btnType -eq $BS_3STATE   -or $btnType -eq $BS_AUTO3STATE)

        [void]$list.Add([pscustomobject]@{
            Handle     = $h
            Class      = $cls.ToString()
            Text       = ($txt.ToString() -replace '&', '').Trim()
            Enabled    = [Native.Win32Menu]::IsWindowEnabled($h)
            Visible    = [Native.Win32Menu]::IsWindowVisible($h)
            IsCheckbox = $isCheck
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

# Snapshot every visible top-level window that has a title, as
# handle -> title. Used to spot the Guiding Assistant appearing without
# knowing what it is called in the user's language.
function Get-TopLevelWindowMap {
    $map = @{}
    try {
        $h = [IntPtr]::Zero
        for ($n = 0; $n -lt 400; $n++) {
            $h = [Native.Win32Menu]::FindWindowExW([IntPtr]::Zero, $h, $NULLSTR, $NULLSTR)
            if ($h -eq [IntPtr]::Zero) { break }
            if (-not [Native.Win32Menu]::IsWindowVisible($h)) { continue }
            $sb = New-Object System.Text.StringBuilder 512
            [void][Native.Win32Menu]::GetWindowTextW($h, $sb, 512)
            $t = $sb.ToString().Trim()
            if ($t) { $map[[string]$h] = $t }
        }
    } catch { }
    return $map
}

function Get-GAControls {
    param([IntPtr]$GaHwnd, [string]$TextPattern)
    $hits = New-Object System.Collections.ArrayList
    foreach ($c in (Get-ChildControls $GaHwnd)) {
        if ($c.Class -eq 'Button' -and $c.Text -like $TextPattern) { [void]$hits.Add($c) }
    }
    return $hits
}

# Localised lookups: try each candidate caption in turn. Patterns are
# ordered English first, so an English PHD2 never pays for the rest.
function Get-GAControlAny {
    param([IntPtr]$GaHwnd, [string[]]$Patterns)
    $controls = Get-ChildControls $GaHwnd
    foreach ($pat in $Patterns) {
        foreach ($c in $controls) {
            if ($c.Class -eq 'Button' -and $c.Text -like $pat) { return $c }
        }
    }
    return $null
}

function Get-GAControlsAny {
    param([IntPtr]$GaHwnd, [string[]]$Patterns)
    $controls = Get-ChildControls $GaHwnd
    $hits = New-Object System.Collections.ArrayList
    foreach ($pat in $Patterns) {
        foreach ($c in $controls) {
            if ($c.Class -eq 'Button' -and $c.Text -like $pat) { [void]$hits.Add($c) }
        }
        if ($hits.Count -gt 0) { break }   # first pattern that matches wins
    }
    return $hits
}

# =====================================================================
#  LANGUAGE-INDEPENDENT CONTROL IDENTIFICATION
# ---------------------------------------------------------------------
#  Captions are translated; structure is not. When no caption pattern
#  matches - a language nobody has mapped, or a non-Latin script where
#  the wildcard trick cannot work at all - fall back to what the dialog
#  is rather than what it says.
#
#  Verified against the English, German and French dialogs, which all
#  enumerate their trailing controls in the same order:
#
#      <backlash checkbox> , <status text> , Start , OptionsButton , Stop
#
#  'OptionsButton' is a wxWidgets internal name and is NOT localised,
#  which makes it a dependable anchor.
# =====================================================================

# The backlash control is the only checkbox in the dialog, and a
# checkbox announces itself through its window style rather than its
# caption.
function Get-GACheckboxByStyle {
    param([IntPtr]$GaHwnd)
    foreach ($c in (Get-ChildControls $GaHwnd)) {
        if ($c.IsCheckbox) { return $c }
    }
    return $null
}

# Start and Stop by position relative to the OptionsButton anchor.
# Returns a hashtable with Start and Stop, either of which may be null.
function Get-GAStartStopByPosition {
    param([IntPtr]$GaHwnd)

    $controls = @(Get-ChildControls $GaHwnd)
    $anchor = -1
    for ($i = 0; $i -lt $controls.Count; $i++) {
        if ($controls[$i].Text -eq 'OptionsButton') { $anchor = $i; break }
    }
    if ($anchor -lt 0) { return @{ Start = $null; Stop = $null } }

    # Start: the last Button before the anchor
    $start = $null
    for ($i = $anchor - 1; $i -ge 0; $i--) {
        if ($controls[$i].Class -eq 'Button' -and -not $controls[$i].IsCheckbox) {
            $start = $controls[$i]; break
        }
    }
    # Stop: the first Button after the anchor
    $stop = $null
    for ($i = $anchor + 1; $i -lt $controls.Count; $i++) {
        if ($controls[$i].Class -eq 'Button' -and -not $controls[$i].IsCheckbox) {
            $stop = $controls[$i]; break
        }
    }
    return @{ Start = $start; Stop = $stop }
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
# declination backlash run instead of finishing the session. Not a
# hazard - PHD2 measures backlash with north/south guide pulses, so the
# star moves a few arcseconds and the mount stays put - but it extends
# the run by several minutes and produces a measurement we did not ask
# for. Georg measures backlash deliberately, occasionally, by hand.
# wxCheckBox is a Win32 "Button" class control, so we find it by caption
# and read its state with BM_GETCHECK.
function Ensure-BacklashUnchecked {
    param([IntPtr]$GaHwnd)

    # NB: the pattern must be specific. '*Backlash*' also matches the
    # 'Show Backlash Graph' pushbutton, which appears EARLIER in the
    # enumeration and always reports BM_GETCHECK = 0 - so the script
    # cheerfully reported the box as unchecked while it was ticked.
    $cb = Get-GAControlAny $GaHwnd $GABacklashPatterns
    if (-not $cb) {
        # No caption matched - identify it structurally instead.
        $cb = Get-GACheckboxByStyle $GaHwnd
        if ($cb) {
            Write-Log ("No backlash caption matched; identified it by control style instead: '{0}'." -f $cb.Text) 'WARN'
            Write-Log "Add that caption to -GABacklashPatterns to match it directly in future." 'WARN'
        }
    }
    if (-not $cb) {
        Write-Log "Could not locate the backlash checkbox, by caption or by style - continuing." 'WARN'
        return
    }

    $state = ([Native.Win32Menu]::SendMessageW($cb.Handle, [uint32]$BM_GETCHECK, [IntPtr]::Zero, [IntPtr]::Zero)).ToInt32()
    if ($state -ne 0) {
        Write-Log ("Backlash checkbox '{0}' was checked - unchecking it." -f $cb.Text)
        Click-Control $cb
        Start-Sleep -Milliseconds 500
        $state = ([Native.Win32Menu]::SendMessageW($cb.Handle, [uint32]$BM_GETCHECK, [IntPtr]::Zero, [IntPtr]::Zero)).ToInt32()
        if ($state -ne 0) {
            Write-Log "Backlash checkbox is STILL checked after clicking it." 'WARN'
        } else {
            Write-Log "Backlash checkbox is now unchecked."
        }
    } else {
        Write-Log ("Backlash checkbox '{0}' is unchecked, as required." -f $cb.Text)
    }
}

# PHD2 enforces a two-minute minimum sampling period. If Stop is clicked
# earlier it opens an 'Extended Sampling' window with a countdown and
# keeps measuring; recommendations - and the Apply buttons themselves -
# do not exist until that finishes. Wait it out.
# After Stop is clicked PHD2 may not be finished: it tops short runs up
# to its two-minute minimum ('Extended Sampling'), and if the backlash
# checkbox was left ticked it starts a backlash measurement instead.
#
# We deliberately do NOT depend on recognising those windows by title -
# they are localised, and chasing translations for every state PHD2 can
# enter is a losing game. Instead we simply wait for the Apply buttons
# to appear, whatever PHD2 is doing meanwhile. That is language-neutral.
function Note-ExtendedSampling {
    Start-Sleep -Seconds 2
    if ((Find-TopWindowByTitle 'Extended Sampling') -ne [IntPtr]::Zero) {
        Write-Log "PHD2 opened 'Extended Sampling' - topping up to its 2-minute minimum. Waiting for results."
    }
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

    $positionalNoted = $false
    while ((Get-Date) -lt $deadline) {
        $startBtn = Get-GAControlAny $gaWindow $GAStartPatterns
        $stopBtn  = Get-GAControlAny $gaWindow $GAStopPatterns

        # Neither caption recognised? Identify them by position instead.
        if (-not $startBtn -and -not $stopBtn) {
            $byPos = Get-GAStartStopByPosition $gaWindow
            $startBtn = $byPos.Start
            $stopBtn  = $byPos.Stop
            if (-not $positionalNoted -and ($startBtn -or $stopBtn)) {
                Write-Log ("No Start/Stop caption matched. Identified them by position: Start='{0}', Stop='{1}'." -f `
                           $(if ($startBtn) { $startBtn.Text } else { '?' }),
                           $(if ($stopBtn)  { $stopBtn.Text }  else { '?' })) 'WARN'
                Write-Log "Add those captions to -GAStartPatterns / -GAStopPatterns to match them directly in future." 'WARN'
                $positionalNoted = $true
            }
        }

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

    # Remember which controls exist now: the Apply buttons do not yet
    # exist, so anything new afterwards is a strong candidate.
    $btnHandlesBeforeStop = @{}
    foreach ($c in (Get-ChildControls $gaWindow)) {
        if ($c.Class -eq 'Button') { $btnHandlesBeforeStop[[string]$c.Handle] = $true }
    }

    Write-Log "Clicking Stop."
    $stopBtn = Get-GAControlAny $gaWindow $GAStopPatterns
    if (-not $stopBtn) { $stopBtn = (Get-GAStartStopByPosition $gaWindow).Stop }
    if ($stopBtn -and $stopBtn.Enabled) { Click-Control $stopBtn }
    else { Write-Log "'Stop' button not available - GA may have ended by itself." 'WARN' }

    # PHD2 may insist on more sampling before it will show results.
    Note-ExtendedSampling

    # ---------- 5. Apply the recommendations -------------------------
    # The Apply buttons are created only when the recommendations render,
    # so poll for them rather than assuming they already exist.
    # Poll generously. PHD2 can still be sampling, or working through a
    # backlash measurement, and the buttons do not exist until it is done.
    $applyBtns = @()
    $deadline  = (Get-Date).AddSeconds($ApplyWaitSec)
    $lastNote  = Get-Date
    $foundByCaption = $false
    while ((Get-Date) -lt $deadline) {
        $applyBtns = @(Get-GAControlsAny $gaWindow $GAApplyPatterns)
        if ($applyBtns.Count -gt 0) { $foundByCaption = $true; break }

        # Language-independent fallback: the Apply buttons are created
        # when the recommendations render, so any Button that did not
        # exist before we clicked Stop is a candidate.
        $fresh = New-Object System.Collections.ArrayList
        foreach ($c in (Get-ChildControls $gaWindow)) {
            if ($c.Class -eq 'Button' -and -not $c.IsCheckbox -and
                -not $btnHandlesBeforeStop.ContainsKey([string]$c.Handle)) {
                [void]$fresh.Add($c)
            }
        }
        if ($fresh.Count -gt 0) {
            $applyBtns = @($fresh)
            break
        }

        if (((Get-Date) - $lastNote).TotalSeconds -ge 30) {
            $remaining = [int]($deadline - (Get-Date)).TotalSeconds
            Write-Log "Still waiting for the recommendations to appear - ${remaining}s left."
            $lastNote = Get-Date
        }
        Start-Sleep -Seconds 1
    }

    if ($applyBtns.Count -gt 0) {
        if ($foundByCaption) {
            Write-Log ("Found {0} apply button(s), captioned '{1}'." -f $applyBtns.Count, $applyBtns[0].Text)
        } else {
            Write-Log ("No apply caption matched. Found {0} newly-created button(s) instead, captioned '{1}'." -f `
                       $applyBtns.Count, $applyBtns[0].Text) 'WARN'
            Write-Log "Add that caption to -GAApplyPatterns to match it directly in future." 'WARN'
        }
    } else {
        Write-Log "Found 0 apply buttons, by caption or by creation order."
    }

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

    # One retry for anything still enabled. A posted BM_CLICK can be
    # missed while the dialog is rebuilding its recommendations panel.
    Start-Sleep -Seconds 1
    $retried = 0
    foreach ($b in (Get-GAControlsAny $gaWindow $GAApplyPatterns)) {
        if ($b.Enabled) {
            Write-Log ("An apply button is still enabled - clicking it again.") 'WARN'
            Click-Control $b
            $retried++
            Start-Sleep -Milliseconds 800
        }
    }
    if ($retried -gt 0) { Start-Sleep -Seconds 1 }

    $raAfter  = Phd-GetMinMove 'ra'  $raParam
    $decAfter = Phd-GetMinMove 'dec' $decParam
    Write-Log ("Min-move after:  RA={0}  Dec={1}" -f $raAfter, $decAfter)

    # How do we know the clicks landed?
    #
    # Not by "did the numbers change" - PHD2 frequently recommends values
    # a rig is already using, in which case applying them changes
    # nothing. That is a correct outcome, not a failure. (Observed
    # 2026-07-31: recommendations of RA 0.10 / Dec 0.15 against current
    # values of exactly 0.1 and 0.15.)
    #
    # Nor by "are all buttons now disabled" - PHD2 does not reliably
    # disable a button whose recommendation was already satisfied.
    #
    # So: success if the values moved, OR if at least one button we
    # clicked went from enabled to disabled - proof that clicking works
    # at all. Only when neither holds is something genuinely wrong.
    $nowEnabled = @{}
    foreach ($b in (Get-GAControlsAny $gaWindow $GAApplyPatterns)) {
        $nowEnabled[[string]$b.Handle] = $b.Enabled
    }
    $wentDisabled = 0
    $stillEnabled = 0
    foreach ($b in $applyBtns) {
        $key = [string]$b.Handle
        if ($nowEnabled.ContainsKey($key)) {
            if ($nowEnabled[$key]) { $stillEnabled++ } else { $wentDisabled++ }
        } else {
            $wentDisabled++      # button gone entirely - certainly acted upon
        }
    }

    $valuesChanged = -not (($raAfter -eq $raBefore) -and ($decAfter -eq $decBefore))

    if (-not $valuesChanged) {
        if ($wentDisabled -eq 0) {
            Log-GAControls $gaWindow
            Fail 44 ("Min-move values unchanged and none of the {0} 'Apply' button(s) responded - the clicks did not take." -f $applyBtns.Count)
        }
        if ($stillEnabled -gt 0) {
            Write-Log ("Min-move values unchanged. {0} button(s) responded, {1} still enabled - PHD2 most " +
                       "likely recommended values this rig already uses, so applying them changed nothing." -f `
                       $wentDisabled, $stillEnabled) 'WARN'
        } else {
            Write-Log ("Min-move values are unchanged, but every 'Apply' button responded. PHD2 simply " +
                       "recommended the values already in use.") 'WARN'
        }
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
