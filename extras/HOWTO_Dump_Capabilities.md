# How to run Dump-AscomCapabilities.ps1

Thanks for helping. This takes about two minutes.

## What it does

It asks your mount's ASCOM driver what it can do — whether it supports
Find Home, parking, async slewing, pulse guiding and so on — and prints
the answers. We're collecting these across different mounts because
drivers vary more than the documentation suggests, and scripts that
drive a telescope need to know which calls are safe to make.

## Is it safe?

Yes. It is **read only**:

- It never slews, parks, homes, or changes tracking
- It never writes to the driver or changes any setting
- It does **not** disconnect your mount when it finishes, so it won't
  disturb N.I.N.A., SGP or anything else that's connected

It's safe to run with the mount powered on, tracking, and in use.

## What you need

- Windows with PowerShell (the built-in one is fine)
- The ASCOM Platform installed — you'll have this already if you use
  N.I.N.A., SGP or similar
- Your mount's ASCOM driver installed

## Important: connect the mount first

**Please run this with the mount powered on and connected.** Drivers
report different capabilities when idle than when they're actually
talking to hardware — we found one that claims it can't Find Home when
no mount is attached, but can once connected. A dump taken with the
mount switched off is much less useful.

If your mount is already connected in N.I.N.A. or another program,
that's ideal. Leave it connected and just run this alongside.

## Running it — pick whichever you prefer

Both do exactly the same thing. Option A just types the command for you.
(Both use PowerShell underneath — it's built into Windows, so you have
it either way.)

---

### Option A — double-click, no typing

1. Put **both** files in the same folder, anywhere you like:
   - `Run_Dump-AscomCapabilities.bat`
   - `Dump-AscomCapabilities.ps1`
2. Make sure your mount is powered on and connected
3. **Double-click `Run_Dump-AscomCapabilities.bat`**
4. Press a key when prompted, then pick your mount in the chooser
5. Send back **`ascom_dump.txt`**, which appears in the same folder

---

### Option B — run the command yourself

Works from **Command Prompt or PowerShell**, and changes no system
settings:

```
powershell -NoProfile -ExecutionPolicy Bypass -File Dump-AscomCapabilities.ps1
```

Run it from the folder containing the script, or give the full path to
it. `-ExecutionPolicy Bypass` applies only to that one command — nothing
on your machine is changed permanently.

A driver chooser opens; pick your mount. Then copy everything the script
printed and send it back.

To skip the chooser and name your driver directly — for a ZWO
AM3/AM5/AM7:

```
powershell -NoProfile -ExecutionPolicy Bypass -File Dump-AscomCapabilities.ps1 -ProgId "ASCOM.ASIMount.Telescope" -MountLabel "ZWO AM5"
```

`-MountLabel` is optional; it just gives the summary line a tidier name
than the driver's own, which is sometimes a 70-character list of model
numbers.

## Not sure what drivers you have?

This lists every telescope driver installed on the machine:

```powershell
$p = New-Object -ComObject ASCOM.Utilities.Profile
$p.RegisteredDevices('Telescope') | ForEach-Object { "{0}  =  {1}" -f $_.Key, $_.Value }
```

## What to send back

**Option A:** just send `ascom_dump.txt` — everything is already in it.

**Option B:** copy everything the script printed, from the
`ASCOM capability dump` header down to the last line, and paste it into
an email.

Please also mention:

- Which mount you have
- Whether it was **connected and powered on** when you ran it

## If something goes wrong

- **"Dump-AscomCapabilities.ps1 was not found"** — the two files aren't
  in the same folder (Option A)
- **"running scripts is disabled on this system"** — you double-clicked
  or ran the `.ps1` directly. Use Option A or the exact command in
  Option B, both of which handle this
- **It fails to connect** — the driver may need the mount powered on and
  on the right COM port. Send the error text anyway, that's useful too
- **The window closes instantly** — run it from a command prompt so you
  can read the error

Any error output is still worth sending. A driver that refuses to do
something is exactly the kind of thing we want to know about.
