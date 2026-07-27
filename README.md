# PHD2 Guiding Assistant automation — design notes

Companion to `PHD2_GuidingAssistant.ps1` and `Run_PHD2_GuidingAssistant.bat`.
Written 26 July 2026 for the AtlasII / RC51 rig.

## Rig context

| Item | Value |
|---|---|
| Mount | Sky-Watcher EQ6-R Pro |
| Mount driver | GS Server (GSS) v1.2.2.4 Beta, ProgID `ASCOM.GS.Sky.Telescope` |
| Guiding | PHD2 2.6.14, profile `Atlas2_290MM`, instance 1 → **port 4400** |
| Imaging | N.I.N.A. 3.2, profile `AtlasII_RC51_2600C` |
| Guide exposure | 2 s |
| Guide scope FL | 120 mm |
| Access | Remote — laptop → mini PC |

## What the script does

1. Connects to PHD2 (TCP 4400) and to the mount through GSS.
2. Pre-flight: PHD2 reachable, equipment connected, **calibration exists**.
3. Slews to Dec 0°, hour angle +5° (west of meridian), approaching from
   1° **south** so the final move is northward and clears Dec backlash.
4. `stop_capture` → `loop` → `find_star` → `guide` (with `recalibrate: false`).
5. Opens the Guiding Assistant, runs it for 130 s, stops it, clicks every
   enabled `Apply` button.
6. Verifies the min-move values actually changed, via the API.
7. `stop_capture`, then `FindHome()`, then exits.

Runs once per night, from `0-RC51 - My Startup`, replacing the
`Manual Guiding assistant` message box.

## Key design decisions and why

**Why UI Automation for the Guiding Assistant.**
PHD2's RPC API has no Guiding Assistant method — the full method list
(`capture_single_frame`, `guide`, `dither`, `guide_pulse`, `set_algo_param`,
…) contains nothing for GA, and no way to click Accept. GA is GUI-only.
UIA addresses controls through the accessibility tree by name, not by
pixel coordinates, so **display scaling and DPI are irrelevant**.

**Why the backlash bump is in Dec, not RA.**
The original request said "bump the mount in RA to clear backlash". PHD2's
own Calibration Assistant does two slews — first south of the target, then
1° north — and that northward move is the backlash-clearing step. RA
backlash is continuously taken up by the tracking motor, so there is
normally nothing to clear on that axis. The script replicates PHD2's
behaviour.

**Why the script slews directly instead of driving the Calibration Assistant.**
Fewer fragile UI-automation targets, and the PHD2 manual warns the CA is
"only usable in interactive mode" when guiding is controlled by a separate
imaging application — which N.I.N.A. is.

**Why PowerShell.**
No Python on the mini PC. PowerShell 5.1 ships with Windows and covers all
three needs with zero installs: `TcpClient` for JSON-RPC,
`System.Windows.Automation` for UIA, COM for ASCOM.

**Why it never calibrates.**
Two guards: `get_calibrated` must return true or the script aborts with
exit 12, and the `guide` call passes `recalibrate: false` explicitly.

**Why it stops capture before homing.**
N.I.N.A. holds its own PHD2 connection all night. Leaving PHD2 guiding
while the mount goes to Dec 90° with tracking off would lose the star and
leave N.I.N.A.'s later "start guiding" step in a confused state.

**Why it does not disconnect the mount.**
GSS is a hub. The script opens its own client connection and closes it
again on the way out, which does not disturb N.I.N.A.'s separate client
connection. Caveat observed on 2026-07-26: if the script is the *only*
client, closing its connection makes GSS drop the hardware link
entirely. In production N.I.N.A. connects all equipment at sunset, well
before this instruction runs, so the link stays up.

**On syncing after TPPA — deliberately not done.**
Turning the alt/az bolts moves the physical RA axis *closer* to the pole,
so the mount's built-in assumption becomes more correct, not less. Encoders
never moved; home is still home. Closed-loop plate solving (Target Scheduler
centering, `Center After Drift`) already corrects pointing per target, which
beats a hand-built sync model. A bad sync point degrades every later slew.
If better blind-slew accuracy is ever wanted, one `Solve and sync` after the
last TPPA round is the proportionate answer.

## Verified PHD2 settings (Advanced Settings → Guiding)

- `Clear mount calibration` — **unchecked** ✔ (required)
- `Auto restore calibration` — checked ✔
- `Use Dec compensation` — checked (needs mount pointing info)
- `Stop guiding when mount slews` — checked (harmless; script slews before guiding)
- Calibration step 900 ms, focal length 120 mm, search region 15 px

PHD2 reports `Pier Side` and `Declination` in Guide Stats, confirming a
working mount/aux-mount connection.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (possibly with a logged warning) |
| 10 | PHD2 unreachable / server not enabled |
| 11 | PHD2 equipment not connected |
| 12 | PHD2 not calibrated — script refuses to calibrate |
| 20 | Mount connect failed |
| 21 | Slew failed or timed out |
| 22 | Post-slew position sanity check failed |
| 23 | Mount reports an invalid sidereal time or site location |
| 24 | Driver lacks a capability the script requires |
| 30 | No guide star found |
| 31 | Guiding failed to settle |
| 40 | GA window did not appear |
| 41 | GA `Start` button never enabled |
| 42 | Star lost / PHD2 error alert during the GA run |
| 43 | No `Apply` buttons offered |
| 44 | Min-move values unchanged after Apply |
| 50 | Stand-down (`FindHome` / `Park`) failed or timed out |
| 99 | Unexpected error |

A non-zero exit fails the N.I.N.A. instruction and will fire the
`Failures to Pushover` global trigger (Emergency / Siren). The script
always attempts `stop_capture` + `FindHome()` before exiting, so the rig
is left safe. A timestamped log is written beside the script.

## Why the GA dialog is driven with raw Win32, not UI Automation

The first three versions used UIA and failed three different ways. What
we learned, in order:

1. **Menus are not UIA children.** Windows menus are `HMENU` objects, not
   child windows, so a `TreeScope::Descendants` search from the main
   window never reaches them. Solved by walking the `HMENU`, reading the
   command ID for "Guiding Assistant...", and posting `WM_COMMAND`.
2. **`$null` is not null.** PowerShell marshals `$null` to an *empty
   string* for .NET `string` parameters, so `FindWindow(null, "Guiding
   Assistant")` searched for window class `""` and found nothing. Use
   `[NullString]::Value`.
3. **UIA can see the GA window but none of its contents.** wxWidgets
   dialogs expose poorly through the MSAA-to-UIA bridge. All control
   access is therefore native Win32: recursive `FindWindowEx` to
   enumerate children (controls are nested inside panels, so a
   single-level scan misses them), match on class `Button` plus caption,
   click with `BM_CLICK`, read checkbox state with `BM_GETCHECK`, close
   with `WM_CLOSE`.

The script logs the dialog's full control list whenever it opens or
fails, which is what made each of these diagnosable in one run.

## Two behaviours of PHD2 worth knowing

**GA auto-starts.** If guiding is already active when the dialog opens —
which it always is here — PHD2 begins measuring immediately and the
`Start` button is *disabled*. Waiting for `Start` to become enabled hangs
forever. The script detects which of `Start`/`Stop` is enabled and acts
accordingly.

**Stopping early triggers "Extended Sampling".** Click Stop before two
minutes and PHD2 opens a countdown window and keeps measuring until it
reaches its minimum. Recommendations, and the Apply buttons themselves,
do not exist until that completes. The script waits for that window to
disappear before looking for results.

## A trap: '*Backlash*' matches two controls

The dialog contains both `Show Backlash Graph` (a pushbutton) and
`Measure Declination Backlash` (the checkbox), and the pushbutton comes
first in enumeration order. Matching `'*Backlash*'` returned the
pushbutton, whose `BM_GETCHECK` is always 0 — so the script reported the
box as unchecked while it was visibly ticked. The pattern must be
`'Measure*Backlash*'`.

## GA duration floor — 120 s

PHD2 will not populate the Recommendations panel unless the baseline
sampling ran for **at least 120 seconds**. Below that the run completes
normally but offers no Apply buttons, which this script reports as
exit 43. `-GASeconds` must therefore stay above 120; the production
value is 130. The script logs a warning if it is set lower.

## Known risks

1. **Opening GA from the Tools menu.** The first version used UIA for this
   and failed with exit 40 on the very first run: Windows menus are
   `HMENU` objects, not child windows, so a UIA descendants search from
   the main window never reaches them. Now handled by walking the native
   `HMENU`, reading the command ID for "Guiding Assistant...", and posting
   `WM_COMMAND` — the same thing a mouse click does. UIA and `SendKeys`
   remain as fallbacks 2 and 3. On failure the log prints every menu
   caption it saw.
2. **Disconnected RDP sessions have no rendered desktop**, and UIA may fail.
   Stay connected to the mini PC for the ~6 minutes this runs. (In the
   normal workflow you are, since you have just finished TPPA by hand.)
3. **Exit 44 when values legitimately don't change.** This bit us twice on
   2026-07-26: two consecutive runs against the deterministic simulator
   produced identical recommendations, so the min-move values were
   unchanged and the script wrongly concluded the Apply clicks had
   missed. Now resolved by checking whether PHD2 *disabled* the Apply
   buttons — its own signal that a recommendation was applied — and
   failing only if the values are unchanged AND the buttons are still
   live.
4. Coordinates are computed as topocentric-of-date from `SiderealTime`. If
   the driver reports J2000 there is a ~0.4° precession discrepancy —
   irrelevant at a 5° offset.

## Test status

| Stage | What | Result |
|---|---|---|
| 1 | Parse check | Pass |
| 2 | `-Simulate`, PHD2 Simulator profile, 130 s | **Pass — exit 0**, 2026-07-26 |
| 3 | Real mount slew + FindHome | **Pass** (accidental full run, 2026-07-26 15:51) — reached Dec 0.00, HA 5.03° W, SideOfPier=0, homed cleanly |
| 4 | Launched from N.I.N.A., real mount, PHD2 simulator | **Pass — exit 0**, 2026-07-26 21:18, 4m00s end to end |
| 5 | Full run on the real rig under real sky | Not yet done |

Stage 2 verified end to end: menu → window → backlash unchecked →
auto-start detected → 130 s run → Stop → 2 Apply buttons clicked →
min-move confirmed changed via the API (RA 0.18 → 0.0975,
Dec 0.18 → 0.15) → capture stopped → exit 0.

## Before the first real-sky run

- Switch PHD2 back to the `Atlas2_290MM` profile
- Restore `Search region` to 15 px if it was raised for simulator testing
- Confirm the mount is connected and `Tools > Enable Server` is checked
- Point the N.I.N.A. External Script instruction at
  `Run_PHD2_GuidingAssistant.bat` (not the TEST batch)
- Expect ~6 minutes: slew, settle, 130 s GA, apply, home

## Before first use

```powershell
# 1. Parse check
$e=$null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    'C:\Users\ggalb\Documents\COWORK\NINA Support Scripts\PHD2_GuidingAssistant.ps1',
    [ref]$null,[ref]$e); $e

# 2. Dry run — exercises PHD2 + GA automation, moves nothing
.\PHD2_GuidingAssistant.ps1 -Simulate
```

Then a full run against the PHD2 camera simulator and the GSS mount
simulator before trusting it on the real rig.

## Portability

Developed against one setup — EQ6-R Pro via GS Server, PHD2 2.6.14 with
an English UI, N.I.N.A. 3.2, Windows 11 — but nothing is tied to a
particular PHD2 *profile*, and the mount driver is a parameter
(`-MountProgId`), so EQMOD (`EQMOD.Telescope`), iOptron
(`ASCOM.iOptron2017.Telescope`), ZWO (`ASCOM.ASIMount.Telescope`) or any
other ASCOM driver can be passed in.

### Done (2026-07-27)

- **Capabilities are read at runtime**, after connecting to the actual
  mount, and logged. See the warning in
  `ASCOM_Mount_Capabilities.md`: flags are *not* static per driver, so a
  lookup table would be wrong.
- **`-EndAction`** accepts `Auto` (default), `Home`, `Park` or `None`.
  `Auto` prefers `FindHome()`, falls back to `Park()`, and warns if the
  driver supports neither.
- **Slew falls back** to the blocking `SlewToCoordinates()` when
  `CanSlewAsync` is false.
- **Unpark and tracking are checked** against `CanUnpark` and
  `CanSetTracking`, failing early with exit 24 rather than throwing.
- **Site and sidereal time are validated before any movement** (exit 23).
  Prompted by the ZWO driver reporting `SiderealTime = -1` and the
  iOptron reporting site 0,0 while idle — either would have produced a
  meaningless target and slewed the mount to it.
- **`SideOfPier` is only used when meaningful**; `pierUnknown` degrades
  the post-slew check to declination and hour angle only.

### Still open

1. **English-language PHD2 assumed.** The window title
   `Guiding Assistant`, the menu caption, and the captions `Start`,
   `Stop`, `Apply` and `Measure Declination Backlash` are matched as
   literal English strings. A localised PHD2 fails at exit 40. Could be
   lifted into parameters.
2. **GEM assumed** in the positioning logic. Alt-az mounts now get a
   warning, but "Dec 0, 5° west of the meridian" still isn't meaningful
   for them.
3. **Guide star SNR is not checked** after settling. A marginal star
   means 130 s of measurement producing recommendations from a star that
   keeps dropping out. Aborting early would be better.
4. **`MaxStarLost = 8`** during the GA run is a guess, never calibrated
   against real sky.

Southern hemisphere is *not* a concern: approaching from the south and
finishing northward is correct in both, and a GEM pointing west of the
meridian sits on the east side of the pier either way.

## Licence

MIT — see [LICENSE](LICENSE). Provided as-is, with no warranty. This
script commands a telescope mount; test it against simulators before
letting it near your equipment.

## Sources

- [PHD2 server API (EventMonitoring wiki)](https://github.com/OpenPHDGuiding/phd2/wiki/EventMonitoring)
- [PHD2 Tools — Calibration Assistant & Guiding Assistant](https://openphdguiding.org/man-dev/Tools.htm)
- [Green Swamp Software (GSS)](https://greenswamp.org/)
- [GSServer on GitHub](https://github.com/rmorgan001/GSServer)
