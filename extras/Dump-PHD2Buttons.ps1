<#
=====================================================================
 Dump-PHD2Buttons.ps1

 Prints every control in PHD2's MAIN window, with its exact caption.

 WHY THIS EXISTS
   PHD2_GuidingAssistant.ps1 drives PHD2's user interface, and PHD2
   translates its captions. Where a control has a structural signature -
   a menu command ID, a BS_AUTOCHECKBOX style, a position relative to an
   anchor - the script uses that and does not care what language PHD2 is
   in.

   The three "Clear" buttons on the main window have no such signature.
   They can only be matched by caption, so the caption for each language
   has to be known exactly. Reading it off a screenshot is guesswork,
   especially in Cyrillic, Arabic or CJK. This reads it from the running
   application instead.

 HOW TO USE
   1. Start PHD2 and switch it to the language you want to map
      (Tools > Language, then restart PHD2 as it asks).
   2. Connect equipment - some controls do not exist until PHD2 has a
      camera, and a few stay disabled until it is guiding. The
      simulator profile is fine.
   3. Run this script.
   4. Send the output file. Console output mangles non-Latin scripts on
      some code pages; the FILE is written UTF-8 with a BOM and will be
      correct.

 SAFE
   Read-only. It enumerates windows and reads captions. It clicks
   nothing, changes nothing, and never touches the mount.

 Windows PowerShell 5.1. Part of the SpaceHunter N.I.N.A. support
 scripts. MIT licence.
=====================================================================
#>

[CmdletBinding()]
param(
    # Where to write the dump. Defaults to a 'logs' subfolder beside
    # this script.
    [string] $OutFile = '',

    # Main window title to look for. PHD2 appends the profile name, so
    # this is a prefix match.
    [string] $WindowTitlePattern = 'PHD2 Guiding*'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0

# ---------------------------------------------------------------------
#  Win32
# ---------------------------------------------------------------------
if (-not ('PhdDump.Win32' -as [type])) {
    Add-Type -Namespace PhdDump -Name Win32 -MemberDefinition @'
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowExW(IntPtr hWndParent, IntPtr hWndChildAfter,
        string lpszClass, string lpszWindow);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);
'@
}

# PowerShell marshals $null to an EMPTY STRING for .NET string
# parameters, so FindWindow(null, "x") would search for a window whose
# class name is "" and find nothing. This cost two failed test runs
# during development of the main script - do not "simplify" it.
$NULLSTR = [NullString]::Value

$GWL_STYLE        = -16
$BS_TYPEMASK      = 0x0F
$BS_PUSHBUTTON    = 0x00
$BS_DEFPUSHBUTTON = 0x01
$BS_CHECKBOX      = 0x02
$BS_AUTOCHECKBOX  = 0x03
$BS_RADIOBUTTON   = 0x04
$BS_3STATE        = 0x05
$BS_AUTO3STATE    = 0x06
$BS_GROUPBOX      = 0x07

function Get-ButtonKind {
    param([IntPtr]$Hwnd, [string]$Class)
    if ($Class -ne 'Button') { return '' }
    $style = 0
    try { $style = [PhdDump.Win32]::GetWindowLongW($Hwnd, $GWL_STYLE) } catch { return 'button?' }
    switch ($style -band $BS_TYPEMASK) {
        $BS_PUSHBUTTON    { 'pushbutton' }
        $BS_DEFPUSHBUTTON { 'DEFAULT pushbutton' }
        $BS_CHECKBOX      { 'checkbox' }
        $BS_AUTOCHECKBOX  { 'checkbox (auto)' }
        $BS_RADIOBUTTON   { 'radio' }
        $BS_3STATE        { '3-state' }
        $BS_AUTO3STATE    { '3-state (auto)' }
        $BS_GROUPBOX      { 'groupbox' }
        default           { 'button' }
    }
}

# wxWidgets nests controls inside panels and sizers, so a single-level
# scan misses most of them.
function Get-ChildControls {
    param([IntPtr]$Parent, [int]$Depth = 0)

    $list = New-Object System.Collections.ArrayList
    if ($Depth -gt 6) { return $list }

    $h = [IntPtr]::Zero
    for ($i = 0; $i -lt 600; $i++) {
        $h = [PhdDump.Win32]::FindWindowExW($Parent, $h, $NULLSTR, $NULLSTR)
        if ($h -eq [IntPtr]::Zero) { break }

        $cls = New-Object System.Text.StringBuilder 256
        [void][PhdDump.Win32]::GetClassNameW($h, $cls, 256)
        $txt = New-Object System.Text.StringBuilder 1024
        [void][PhdDump.Win32]::GetWindowTextW($h, $txt, 1024)

        $className = $cls.ToString()

        [void]$list.Add([pscustomobject]@{
            Depth   = $Depth
            Handle  = $h
            Class   = $className
            Kind    = (Get-ButtonKind $h $className)
            Text    = $txt.ToString()
            Enabled = [PhdDump.Win32]::IsWindowEnabled($h)
            Visible = [PhdDump.Win32]::IsWindowVisible($h)
        })

        foreach ($c in (Get-ChildControls $h ($Depth + 1))) { [void]$list.Add($c) }
    }
    return $list
}

function Get-TopLevelWindows {
    $out = New-Object System.Collections.ArrayList
    $h = [IntPtr]::Zero
    for ($n = 0; $n -lt 800; $n++) {
        $h = [PhdDump.Win32]::FindWindowExW([IntPtr]::Zero, $h, $NULLSTR, $NULLSTR)
        if ($h -eq [IntPtr]::Zero) { break }
        if (-not [PhdDump.Win32]::IsWindowVisible($h)) { continue }
        $sb = New-Object System.Text.StringBuilder 512
        [void][PhdDump.Win32]::GetWindowTextW($h, $sb, 512)
        $t = $sb.ToString()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $pid2 = 0
        [void][PhdDump.Win32]::GetWindowThreadProcessId($h, [ref]$pid2)
        [void]$out.Add([pscustomobject]@{ Handle = $h; Title = $t; ProcessId = $pid2 })
    }
    return $out
}

function Find-PhdMainWindow {
    foreach ($w in (Get-TopLevelWindows)) {
        if ($w.Title -like $WindowTitlePattern) { return $w }
    }
    return $null
}

# ---------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $dir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = (Get-Location).Path }
    $logDir = Join-Path $dir 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $OutFile = Join-Path $logDir ("PHD2_Buttons_{0:yyyy-MM-dd_HHmmss}.txt" -f (Get-Date))
}

$lines = New-Object System.Collections.ArrayList
function Emit { param([string]$s) [void]$lines.Add($s); Write-Host $s }

$phd = Find-PhdMainWindow
if (-not $phd) {
    Write-Host ""
    Write-Host "PHD2 main window not found (looking for a visible window titled '$WindowTitlePattern')."
    Write-Host "Start PHD2 first, then run this again."
    exit 1
}

Emit "====================================================================="
Emit ("PHD2 main window : '{0}'" -f $phd.Title)
Emit ("Process id       : {0}" -f $phd.ProcessId)
Emit ("Dumped           : {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date))
Emit ("Windows locale   : {0}" -f (Get-Culture).Name)
Emit "====================================================================="

# Every visible top-level window belonging to the PHD2 process, not just
# the main one. If the Guiding Assistant (or any other dialog) is open,
# it gets dumped too - which is how the GA's Start / Stop / Apply /
# backlash captions are captured for a language.
$windows = @(Get-TopLevelWindows | Where-Object { $_.ProcessId -eq $phd.ProcessId })

Emit ""
Emit ("PHD2 has {0} visible top-level window(s):" -f $windows.Count)
foreach ($w in $windows) { Emit ("   '{0}'" -f $w.Title) }
Emit ""

foreach ($w in $windows) {

    Emit ""
    Emit "====================================================================="
    Emit ("WINDOW: '{0}'   handle {1}" -f $w.Title, $w.Handle)
    Emit "====================================================================="

    $controls = @(Get-ChildControls $w.Handle)

    Emit ("BUTTONS ({0}) - these are what the script matches on" -f `
          @($controls | Where-Object { $_.Class -eq 'Button' }).Count)
    Emit "---------------------------------------------------------------------"
    foreach ($c in ($controls | Where-Object { $_.Class -eq 'Button' })) {
        Emit ("  {0,-20} enabled={1,-5} visible={2,-5} '{3}'" -f $c.Kind, $c.Enabled, $c.Visible, $c.Text)
    }

    Emit ""
    Emit ("ALL CONTROLS ({0})" -f $controls.Count)
    Emit "---------------------------------------------------------------------"
    foreach ($c in $controls) {
        $indent = '  ' * ($c.Depth + 1)
        Emit ("{0}{1,-16} enabled={2,-5} visible={3,-5} '{4}'" -f `
              $indent, $c.Class, $c.Enabled, $c.Visible, $c.Text)
    }
}

Emit ""
Emit "====================================================================="
Emit "Send the FILE, not the console output - the console mangles"
Emit "non-Latin scripts on some code pages. The file is UTF-8 with a BOM."
Emit "====================================================================="

# UTF-8 WITH a BOM, deliberately: without one, anything non-ASCII is
# unreadable when opened later, which defeats the whole purpose.
[System.IO.File]::WriteAllLines($OutFile, $lines, (New-Object System.Text.UTF8Encoding $true))

Write-Host ""
Write-Host "Written to: $OutFile"
exit 0
