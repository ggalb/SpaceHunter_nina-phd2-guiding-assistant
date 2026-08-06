<#
=====================================================================
 Convert-AltAzToDecHA.ps1
---------------------------------------------------------------------
 Converts an altitude/azimuth position into the declination and
 meridian offset that PHD2_GuidingAssistant.ps1 expects.

 There is no universal conversion: declination and hour angle are fixed
 relative to the sky, altitude and azimuth are fixed relative to your
 horizon. The mapping between them depends on your observing latitude,
 so you must supply it.

 USAGE
   .\Convert-AltAzToDecHA.ps1 -Alt 46 -Az 90 -Lat 33.798

   Azimuth convention: 0 = North, 90 = East, 180 = South, 270 = West.
   Latitude is negative in the southern hemisphere.

 It also works in reverse, to see where your current settings point:
   .\Convert-AltAzToDecHA.ps1 -Dec 0 -MeridianOffset 5 -Lat 33.798

 NOTE ON A POWERSHELL TRAP
   An earlier version of this maths clamped the sine with
   [Math]::Min(1, $x). Because "1" is an integer literal, PowerShell
   resolved the overload to Math.Min(int, int) and silently truncated
   the double to 0 - producing a declination of exactly 0 for every
   input. Hence the explicit 1.0 / -1.0 below. Worth remembering
   whenever mixing integer literals with [Math] calls.
=====================================================================
#>

[CmdletBinding(DefaultParameterSetName = 'ToDecHA')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ToDecHA')]
    [double] $Alt,

    [Parameter(Mandatory, ParameterSetName = 'ToDecHA')]
    [double] $Az,

    [Parameter(Mandatory, ParameterSetName = 'ToAltAz')]
    [double] $Dec,

    [Parameter(Mandatory, ParameterSetName = 'ToAltAz')]
    [double] $MeridianOffset,

    [Parameter(Mandatory)]
    [ValidateRange(-90, 90)]
    [double] $Lat
)

$D2R = [Math]::PI / 180.0
$R2D = 180.0 / [Math]::PI

# Clamp with explicit doubles - see the note in the header.
function Clamp1 { param([double]$v) return [Math]::Max(-1.0, [Math]::Min(1.0, $v)) }

$p = $Lat * $D2R

if ($PSCmdlet.ParameterSetName -eq 'ToDecHA') {

    $a = $Alt * $D2R
    $z = $Az  * $D2R

    $sinDec = [Math]::Sin($a) * [Math]::Sin($p) + [Math]::Cos($a) * [Math]::Cos($p) * [Math]::Cos($z)
    $dec    = [Math]::Asin((Clamp1 $sinDec))
    $cosDec = [Math]::Cos($dec)

    $sinHA = -[Math]::Sin($z) * [Math]::Cos($a) / $cosDec
    $cosHA = ([Math]::Sin($a) - [Math]::Sin($dec) * [Math]::Sin($p)) / ($cosDec * [Math]::Cos($p))
    $ha    = [Math]::Atan2($sinHA, $cosHA) * $R2D

    $decDeg = $dec * $R2D

    Write-Host ""
    Write-Host "  Input:  Alt $Alt deg, Az $Az deg, latitude $Lat deg"
    Write-Host ""
    Write-Host "  Enter these in Run_PHD2_GuidingAssistant.bat:"
    Write-Host ""
    Write-Host ("    set `"TARGETDEC={0:N2}`"" -f $decDeg)
    Write-Host ("    set `"MERIDIANOFFSET={0:N2}`"" -f $ha)
    Write-Host ""
    $side = if ($ha -ge 0) { 'WEST of the meridian' } else { 'EAST of the meridian' }
    Write-Host ("  That is {0:N2} deg ({1:N2} hours) {2}." -f [Math]::Abs($ha), [Math]::Abs($ha / 15), $side)

    if ([Math]::Abs($ha) -gt 30) {
        Write-Host ""
        Write-Host ("  WARNING: {0:N1} deg is {1:N1} hours from the meridian. PHD2 recommends" -f [Math]::Abs($ha), [Math]::Abs($ha/15))
        Write-Host  "  staying within about two hours (30 deg). Further out, field rotation"
        Write-Host  "  and differential flexure start contaminating what is meant to be a"
        Write-Host  "  seeing measurement."
    }
    if ([Math]::Abs($decDeg) -gt 40) {
        Write-Host ""
        Write-Host ("  WARNING: declination {0:N1} compresses RA corrections by cos(dec)," -f $decDeg)
        Write-Host  "  which makes the RA min-move recommendation less representative."
    }
    if ($Alt -lt 30) {
        Write-Host ""
        Write-Host ("  WARNING: altitude {0:N1} deg means looking through a lot of atmosphere." -f $Alt)
    }
    Write-Host ""
}
else {

    $d = $Dec * $D2R
    $h = $MeridianOffset * $D2R

    $sinAlt = [Math]::Sin($d) * [Math]::Sin($p) + [Math]::Cos($d) * [Math]::Cos($p) * [Math]::Cos($h)
    $alt    = [Math]::Asin((Clamp1 $sinAlt))

    $cosAz = ([Math]::Sin($d) - [Math]::Sin($alt) * [Math]::Sin($p)) / ([Math]::Cos($alt) * [Math]::Cos($p))
    $sinAz = -[Math]::Sin($h) * [Math]::Cos($d) / [Math]::Cos($alt)
    $az    = ([Math]::Atan2($sinAz, (Clamp1 $cosAz)) * $R2D + 360) % 360

    Write-Host ""
    Write-Host "  Input:  Dec $Dec deg, meridian offset $MeridianOffset deg, latitude $Lat deg"
    Write-Host ""
    Write-Host ("  Points at:  Altitude {0:N2} deg,  Azimuth {1:N2} deg" -f ($alt * $R2D), $az)
    Write-Host ""

    if (($alt * $R2D) -lt 0) {
        Write-Host "  WARNING: that position is BELOW THE HORIZON at this latitude."
        Write-Host ""
    }
}
