<#
=====================================================================
 Dump-AscomCapabilities.ps1
---------------------------------------------------------------------
 Connects to any ASCOM telescope driver and reports what it actually
 supports - rather than what the documentation claims.

 Purpose: build a real capability matrix across mounts, so scripts that
 drive a telescope can check before they call. Written because
 PHD2_GuidingAssistant.ps1 calls FindHome(), Unpark() and
 SlewToCoordinatesAsync() unconditionally, which works on an EQ6-R via
 GS Server and would fail on plenty of other mounts.

 USAGE
   # Pick a driver from the ASCOM chooser
   .\Dump-AscomCapabilities.ps1

   # Or name one directly
   .\Dump-AscomCapabilities.ps1 -ProgId 'ASCOM.GS.Sky.Telescope'
   .\Dump-AscomCapabilities.ps1 -ProgId 'EQMOD.Telescope'
   .\Dump-AscomCapabilities.ps1 -ProgId 'ASCOM.Simulator.Telescope'

   # Append a ready-to-paste markdown row to the matrix
   .\Dump-AscomCapabilities.ps1 -ProgId '...' -AppendTo '.\ASCOM_Mount_Capabilities.md'

 NOTES
   - READ ONLY. This script never slews, parks, homes or changes
     tracking. It only reads properties. Safe to run on live hardware.
   - Most drivers will connect without hardware attached, or offer a
     simulator, so you can profile mounts you do not own.
   - Requires the ASCOM Platform.
=====================================================================
#>

[CmdletBinding()]
param(
    [string] $ProgId,
    [string] $AppendTo,
    [string] $MountLabel,          # friendly name for the matrix row
    [switch] $KeepConnected        # leave the driver connected on exit
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------

# Every property is read defensively: ASCOM drivers are entitled to
# throw PropertyNotImplementedException, and several do.
function Get-Prop {
    param($Object, [string]$Name)
    try {
        $v = $Object.$Name
        if ($null -eq $v) { return [pscustomobject]@{ Value = $null; Status = 'null' } }
        return [pscustomobject]@{ Value = $v; Status = 'ok' }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'not implemented|NotImplemented') {
            return [pscustomobject]@{ Value = $null; Status = 'not implemented' }
        }
        return [pscustomobject]@{ Value = $null; Status = "error: $msg" }
    }
}

function Show-Prop {
    param($Object, [string]$Name, [string]$Label = $null)
    if (-not $Label) { $Label = $Name }
    $r = Get-Prop $Object $Name
    if ($r.Status -eq 'ok') {
        $v = $r.Value
        if ($v -is [bool]) { $disp = if ($v) { 'True' } else { 'False' } }
        else { $disp = [string]$v }
    }
    else {
        $disp = "<$($r.Status)>"
    }
    Write-Host ("  {0,-34} {1}" -f $Label, $disp)
    return $r
}

function Bool-Cell {
    param($Result)
    if ($Result.Status -ne 'ok') { return 'n/i' }
    if ($Result.Value) { return 'yes' } else { return 'no' }
}

# ASCOM returns these as bare integers over COM, which are meaningless
# in a matrix. Decode them.
function Decode-AlignmentMode {
    param($Result)
    if ($Result.Status -ne 'ok') { return 'n/i' }
    switch ([int]$Result.Value) {
        0 { 'Alt-Az' }
        1 { 'Polar' }
        2 { 'German Polar (GEM)' }
        default { "unknown ($($Result.Value))" }
    }
}

function Decode-EquatorialSystem {
    param($Result)
    if ($Result.Status -ne 'ok') { return 'n/i' }
    switch ([int]$Result.Value) {
        0 { 'Other' }
        1 { 'Topocentric' }
        2 { 'J2000' }
        3 { 'B1950' }
        default { "unknown ($($Result.Value))" }
    }
}

function Decode-SideOfPier {
    param($Result)
    if ($Result.Status -ne 'ok') { return $Result.Status }
    switch ([int]$Result.Value) {
        -1 { 'pierUnknown' }
         0 { 'pierEast' }
         1 { 'pierWest' }
        default { "unknown ($($Result.Value))" }
    }
}

# ---------------------------------------------------------------------
#  Choose a driver
# ---------------------------------------------------------------------

if (-not $ProgId) {
    try {
        $chooser = New-Object -ComObject 'ASCOM.Utilities.Chooser'
        $chooser.DeviceType = 'Telescope'
        $ProgId = $chooser.Choose('')
    }
    catch {
        throw "Could not open the ASCOM Chooser ($($_.Exception.Message)). Pass -ProgId instead."
    }
    if ([string]::IsNullOrWhiteSpace($ProgId)) {
        Write-Host "No driver selected. Nothing to do."
        return
    }
}

Write-Host ""
Write-Host "=============================================================="
Write-Host " ASCOM capability dump"
Write-Host " ProgID : $ProgId"
Write-Host " Date   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "=============================================================="

$tel        = $null
$weConnected = $false

try {
    $tel = New-Object -ComObject $ProgId

    if (-not $tel.Connected) {
        Write-Host ""
        Write-Host "Connecting..."
        $tel.Connected = $true
        $weConnected = $true
        Start-Sleep -Seconds 2
    } else {
        Write-Host ""
        Write-Host "Driver was already connected - leaving that alone."
    }

    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "IDENTITY"
    $name    = Show-Prop $tel 'Name'
    $desc    = Show-Prop $tel 'Description'
    $drvInfo = Show-Prop $tel 'DriverInfo'
    $drvVer  = Show-Prop $tel 'DriverVersion'
    $ifVer   = Show-Prop $tel 'InterfaceVersion'

    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "GEOMETRY AND COORDINATE SYSTEM"
    $align   = Get-Prop $tel 'AlignmentMode'
    $eqSys   = Get-Prop $tel 'EquatorialSystem'
    $pier    = Get-Prop $tel 'SideOfPier'
    Write-Host ("  {0,-34} {1}" -f 'AlignmentMode',    (Decode-AlignmentMode    $align))
    Write-Host ("  {0,-34} {1}" -f 'EquatorialSystem', (Decode-EquatorialSystem $eqSys))
    Show-Prop $tel 'SiteLatitude'  | Out-Null
    Show-Prop $tel 'SiteLongitude' | Out-Null
    Show-Prop $tel 'SiderealTime'  | Out-Null
    Write-Host ("  {0,-34} {1}" -f 'SideOfPier',       (Decode-SideOfPier       $pier))

    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "CAPABILITIES - parking and homing"
    $canPark     = Show-Prop $tel 'CanPark'
    $canUnpark   = Show-Prop $tel 'CanUnpark'
    $canSetPark  = Show-Prop $tel 'CanSetPark'
    $canFindHome = Show-Prop $tel 'CanFindHome'
    Show-Prop $tel 'AtPark' | Out-Null
    Show-Prop $tel 'AtHome' | Out-Null

    Write-Host ""
    Write-Host "CAPABILITIES - slewing"
    $canSlew        = Show-Prop $tel 'CanSlew'
    $canSlewAsync   = Show-Prop $tel 'CanSlewAsync'
    $canSlewAltAz   = Show-Prop $tel 'CanSlewAltAz'
    $canSlewAltAzA  = Show-Prop $tel 'CanSlewAltAzAsync'
    Show-Prop $tel 'CanSync'      | Out-Null
    Show-Prop $tel 'CanSyncAltAz' | Out-Null

    Write-Host ""
    Write-Host "CAPABILITIES - tracking and rates"
    $canSetTracking = Show-Prop $tel 'CanSetTracking'
    Show-Prop $tel 'Tracking'                    | Out-Null
    Show-Prop $tel 'CanSetRightAscensionRate'    | Out-Null
    Show-Prop $tel 'CanSetDeclinationRate'       | Out-Null
    Show-Prop $tel 'CanSetGuideRates'            | Out-Null

    Write-Host ""
    Write-Host "CAPABILITIES - guiding and manual motion"
    $canPulse    = Show-Prop $tel 'CanPulseGuide'
    Show-Prop $tel 'CanSetPierSide' | Out-Null

    # CanMoveAxis is a METHOD taking an axis index, not a property -
    # reading it as a property just returns the signature.
    foreach ($axis in 0, 1, 2) {
        try {
            $v = $tel.CanMoveAxis($axis)
            Write-Host ("  {0,-34} {1}" -f "CanMoveAxis(axis $axis)", $v)
        } catch {
            Write-Host ("  {0,-34} <not available>" -f "CanMoveAxis(axis $axis)")
        }
    }

    Write-Host ""
    Write-Host "AXIS RATES"
    foreach ($axis in 0, 1) {
        try {
            $rates = $tel.AxisRates($axis)
            if ($rates.Count -eq 0) {
                Write-Host ("  axis {0}: (none reported)" -f $axis)
            }
            foreach ($r in $rates) {
                Write-Host ("  axis {0}: {1:N4} .. {2:N4} deg/sec" -f $axis, $r.Minimum, $r.Maximum)
            }
        } catch {
            Write-Host ("  axis {0}: <not available: {1}>" -f $axis, $_.Exception.Message)
        }
    }

    Write-Host ""
    Write-Host "TRACKING RATES OFFERED"
    try {
        foreach ($tr in $tel.TrackingRates) { Write-Host "  $tr" }
    } catch {
        Write-Host "  <not available: $($_.Exception.Message)>"
    }

    # -----------------------------------------------------------------
    #  Interpretation - what this means for PHD2_GuidingAssistant.ps1
    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "=============================================================="
    Write-Host " RELEVANCE TO PHD2_GuidingAssistant.ps1"
    Write-Host "=============================================================="

    $verdicts = New-Object System.Collections.ArrayList

    if ($canFindHome.Status -eq 'ok' -and $canFindHome.Value) {
        [void]$verdicts.Add("FindHome() supported - the script's end-of-run homing works as written.")
    } else {
        [void]$verdicts.Add("FindHome() NOT supported - the script would fail at exit 50. Needs Park() or a fixed-coordinate slew instead.")
    }

    if ($canSlewAsync.Status -eq 'ok' -and $canSlewAsync.Value) {
        [void]$verdicts.Add("SlewToCoordinatesAsync() supported - the script's slew loop works as written.")
    } else {
        [void]$verdicts.Add("Async slew NOT supported - the script must fall back to the blocking SlewToCoordinates().")
    }

    if ($canUnpark.Status -eq 'ok' -and $canUnpark.Value) {
        [void]$verdicts.Add("Unpark() supported.")
    } else {
        [void]$verdicts.Add("Unpark() NOT supported - the script must skip its unpark step.")
    }

    if ($canSetTracking.Status -eq 'ok' -and $canSetTracking.Value) {
        [void]$verdicts.Add("Tracking is settable.")
    } else {
        [void]$verdicts.Add("Tracking NOT settable - the script cannot guarantee tracking is on before measuring.")
    }

    if ($pier.Status -eq 'ok' -and [int]$pier.Value -ge 0) {
        [void]$verdicts.Add("SideOfPier readable ($(Decode-SideOfPier $pier)) - the post-slew sanity check is meaningful.")
    }
    elseif ($pier.Status -eq 'ok') {
        [void]$verdicts.Add("SideOfPier returns pierUnknown - the sanity check degrades to a declination-only test. NOTE: with no mount connected this may simply be the driver's idle value; re-check against real hardware.")
    }
    else {
        [void]$verdicts.Add("SideOfPier unavailable ($($pier.Status)) - sanity check degrades to a declination-only test.")
    }

    switch ($(if ($eqSys.Status -eq 'ok') { [int]$eqSys.Value } else { -1 })) {
        1 { [void]$verdicts.Add("EquatorialSystem = Topocentric - coordinates computed from SiderealTime are correct as-is, no precession correction needed.") }
        2 { [void]$verdicts.Add("EquatorialSystem = J2000 - coordinates computed from SiderealTime are of-date, so they sit ~0.4 deg from what this driver expects (2026). Negligible at a 5 deg meridian offset, but worth knowing.") }
        3 { [void]$verdicts.Add("EquatorialSystem = B1950 - a large offset from of-date coordinates. The script's positioning would need converting.") }
        0 { [void]$verdicts.Add("EquatorialSystem = Other - the driver does not say what frame it uses. Verify pointing before trusting the slew.") }
        default { [void]$verdicts.Add("EquatorialSystem unavailable - assume of-date and verify pointing.") }
    }

    $alignText = Decode-AlignmentMode $align
    if ($alignText -eq 'Alt-Az') {
        [void]$verdicts.Add("Alt-Az mount - the 'Dec 0, 5 deg west of meridian' positioning assumes a GEM. SideOfPier is meaningless here.")
    } else {
        [void]$verdicts.Add("AlignmentMode = $alignText.")
    }

    foreach ($v in $verdicts) { Write-Host "  - $v" }

    # -----------------------------------------------------------------
    #  Markdown row
    # -----------------------------------------------------------------
    if (-not $MountLabel) {
        if ($name.Status -eq 'ok') { $MountLabel = [string]$name.Value } else { $MountLabel = $ProgId }
    }

    # NB: backtick is PowerShell's escape character, so it cannot be used
    # literally inside a -f format string. Build the code fences from a
    # variable instead.
    $bt = [string][char]0x60

    $row = "| {0} | {1}{2}{1} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} |" -f `
        $MountLabel,
        $bt,
        $ProgId,
        (Decode-AlignmentMode $align),
        (Decode-EquatorialSystem $eqSys),
        (Bool-Cell $canFindHome),
        (Bool-Cell $canPark),
        (Bool-Cell $canUnpark),
        (Bool-Cell $canSlewAsync),
        (Bool-Cell $canSetTracking),
        (Bool-Cell $canPulse)

    Write-Host ""
    Write-Host "=============================================================="
    Write-Host " MATRIX ROW - paste into ASCOM_Mount_Capabilities.md"
    Write-Host "=============================================================="
    Write-Host $row
    Write-Host ""

    if ($AppendTo) {
        try {
            Add-Content -Path $AppendTo -Value $row -Encoding UTF8
            Write-Host "Appended to $AppendTo"
        } catch {
            Write-Host "Could not append to '$AppendTo': $($_.Exception.Message)"
        }
    }
}
catch {
    Write-Host ""
    Write-Host "FAILED: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
}
finally {
    try {
        if ($tel -and $weConnected -and -not $KeepConnected) {
            $tel.Connected = $false
            Write-Host "Disconnected (we opened the connection, so we closed it)."
        }
    } catch { }
    try {
        if ($tel) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($tel) }
    } catch { }
}
