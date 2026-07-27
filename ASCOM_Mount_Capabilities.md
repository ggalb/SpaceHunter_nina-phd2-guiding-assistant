# ASCOM mount capability matrix

Ground truth collected by running `Dump-AscomCapabilities.ps1` against
each driver. **Rows should come from an actual driver dump, not from
documentation or articles** — the whole point is that vendor docs and
secondhand write-ups disagree with what drivers actually report.

```powershell
.\Dump-AscomCapabilities.ps1 -ProgId 'ASCOM.GS.Sky.Telescope' -AppendTo '.\ASCOM_Mount_Capabilities.md'
```

The dump is read-only: it never slews, parks, homes, or changes
tracking. Safe on live hardware.

## ⚠️ Capability flags are NOT static — dump with hardware connected

Established 2026-07-27. The iOptron driver reports `CanFindHome = False`
when connected with **no mount attached**, yet N.I.N.A.'s "Find home"
instruction demonstrably works on a real CEM70EC — and N.I.N.A. calls
`ITelescope.FindHome()`, which it would not offer if the flag were
false. The driver evidently only reports its true capabilities once it
knows which mount is on the other end.

Two consequences:

1. **Any row dumped without hardware is provisional** and marked ⚠️ here.
2. **The hardened script must query capabilities at runtime, after
   connecting to the actual mount** — never from a lookup table, and
   never from this document. This matrix is for understanding the
   landscape and designing fallbacks, not for runtime decisions.

## Why this matters

`PHD2_GuidingAssistant.ps1` currently calls `Unpark()`,
`SlewToCoordinatesAsync()` and `FindHome()` without checking whether the
driver supports them. That works on an EQ6-R Pro through GS Server. On a
mount with no home sensor it fails at exit 50 every run. This matrix
tells us which fallbacks the script actually needs.

## The matrix

| Mount / driver | ProgID | Alignment | EqSystem | FindHome | Park | Unpark | SlewAsync | SetTracking | PulseGuide |
|---|---|---|---|---|---|---|---|---|---|
| Alpaca Telescope Simulator | `ASCOM.Simulator.Telescope` | German Polar (GEM) | Topocentric | yes | yes | yes | yes | yes | yes |
| iOptron CEM/GEM/HEM/HAE/HAZ/SkyHunter | `ASCOM.iOptron2017.Telescope` | German Polar (GEM) | Topocentric | no ⚠️ | yes | yes | yes | yes | yes |
| ZWO AM3/AM5/AM7 | `ASCOM.ASIMount.Telescope` | German Polar (GEM) | Topocentric | yes | yes | yes | yes | yes | yes |
<!-- rows appended by Dump-AscomCapabilities.ps1 go below this line -->

Legend: `yes` / `no` / `n/i` (property not implemented by the driver).

## Per-mount notes

Capability flags don't capture everything. Record here anything the
matrix can't express — whether `FindHome()` blocks or returns
immediately, what "home" physically means, whether `SideOfPier` is
meaningful, how `Sync` behaves, and any driver quirks.

### Sky-Watcher EQ6-R Pro — GS Server (`ASCOM.GS.Sky.Telescope`)

- Verified working with `PHD2_GuidingAssistant.ps1`, 2026-07-26.
- `FindHome()` returns immediately and must be polled via `AtHome` and
  `Slewing`; homing took ~28 s in practice.
- Home = counterweight down, pointing at the pole. The EQ6-R has no home
  sensor; GSS uses its stored zero position.
- Tracking is off after homing.
- Acts as a hub: multiple clients can connect simultaneously. Closing the
  last client's connection drops the hardware link.
- `SideOfPier` reported correctly (`0` = pierEast when pointing west of
  the meridian).

### ASCOM Telescope Simulator (`ASCOM.Simulator.Telescope`)

- Dumped 2026-07-27. Reference row — a driver that supports everything,
  useful as a baseline for comparison.
- Interface version 4, driver 0.5 (Alpaca simulator).
- Supports every capability the script uses, so it makes a poor test for
  fallback paths. To exercise those, a driver that *lacks* `FindHome` is
  needed.
- Axis rates: 0–6.67 and 10–20 deg/sec on both axes.
- Tracking rates: sidereal, king, lunar, solar.

### iOptron CEM120/70/40/26, GEM, HEM, HAE, HAZ, SkyHunter (`ASCOM.iOptron2017.Telescope`)

- Dumped 2026-07-27, driver v9.15, interface version 3.
- **Dumped with NO hardware attached** — the driver connected anyway, but
  `SiteLatitude 0`, `SiteLongitude 0`, `pierUnknown` and `Tracking False`
  are idle defaults, not real values. Capability flags are usually static
  per driver, but re-verify against an actual mount before relying on
  them.
- ⚠️ **`CanFindHome` reported False — but this is WRONG for real
  hardware.** Georg owns a CEM70EC and confirms N.I.N.A.'s "Find home"
  instruction works on it, driving the mount to its zero position.
  N.I.N.A. calls `ITelescope.FindHome()`, which it would not offer if
  `CanFindHome` were false. So the driver reports False only while idle
  with no mount attached, and flips to True once connected to real
  hardware. **Needs re-dumping with the CEM70EC connected.**
- `CanSetRightAscensionRate` and `CanSetDeclinationRate` both False.
- Only `driveSidereal` offered — no lunar, solar or king rates.
- Axis rates are nine discrete steps (min = max on each), 0.0042 to
  2.5 deg/sec, rather than the continuous ranges the simulator reports.
- `CanSyncAltAz` False while `CanSync` is True.
- iOptron's "go to zero position" is functionally equivalent to Find
  Home, and that is what `FindHome()` triggers.

### ZWO AM3 / AM5 / AM7 (`ASCOM.ASIMount.Telescope`)

- Dumped 2026-07-27, driver v6.5.27.0, interface version 3. No hardware
  attached, so reported values are idle defaults.
- **`CanFindHome` = True** — confirms the secondhand claim. The script's
  end-of-run homing works as written on the AM series.
- **`SiderealTime` returned `-1`** — an invalid value, with no site
  configured and no mount connected. Worth knowing because the script
  computes `RA = SiderealTime - offset`; a bogus LST yields a nonsense
  target. See the safety note below.
- **`CanSetPierSide` = False**, unlike the iOptron and the simulator.
  Consistent with a harmonic mount that need not flip at the meridian.
- `CanSlewAltAz` / `CanSlewAltAzAsync` both False — RA/Dec only.
- Tracking rates: sidereal, lunar, solar. No king rate.
- Axis rates: continuous 0–6 deg/sec on both axes.

## Safety finding: validate SiderealTime before slewing

The ZWO dump returned `SiderealTime = -1`, and the iOptron returned
`SiteLatitude = 0, SiteLongitude = 0`. Both are placeholder values from a
driver with no mount and no site.

`PHD2_GuidingAssistant.ps1` computes its target as
`RA = SiderealTime - (MeridianOffsetDeg / 15)`. With an invalid sidereal
time it would compute a meaningless RA and slew there. The post-slew
sanity check would catch the error, but only *after* the mount has moved.

**Fix needed:** validate before the first slew that `SiderealTime` is
within 0–24 and that site latitude/longitude are plausible, and abort
with a clear exit code if not. Added to the hardening list.

### EQMOD (`EQMOD.Telescope`)

- **Not yet dumped.**

## Contributing a dump

If you run a different mount, running the script and sending the output
would be genuinely useful. It connects, reads properties, prints a
matrix row, and disconnects. It moves nothing.
