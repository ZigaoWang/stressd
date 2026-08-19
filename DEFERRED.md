# Deferred

Things that are built and tested against fixtures, but not validated on
hardware, because they need a human at the keyboard or a machine on battery.
Each entry says what is missing and exactly how to close it.

Nothing here is a known bug. These are unverified claims, which is different,
and they are listed so nobody mistakes one for the other.

---

## 1. Battery discharge sign — **done, verified**

Kept here for the record: this was deferred and has since been confirmed on
hardware in both directions. Charging on AC read **+36.9 W**, discharging idle
read **−25.94 W**, discharging under full CPU load read **−34.97 W**. Negative
means discharging.

One finding worth carrying forward: the value is **stale, not noisy**. Over 39
seconds of 1 Hz sampling it changed exactly once, cleanly, when load started.
The rolling median exists to reject spikes and lagged that transition by two
samples, which is expected for a 5-wide window.

---

## 2. A real power curve

**Needs:** battery, and ideally `sudo`.

`stressd calibrate` runs, is unit tested, and has been exercised end to end.
What has not happened is a sweep producing a curve worth committing.

- On AC the only power source is `powermetrics`, which needs root, so the curve
  degrades to utilization-only.
- Two attempts were made on battery. An 11-point sweep ran past 40 minutes
  against a 24-minute estimate — sustained load held the thermal state at
  `.fair`, so every cooldown ran to its cap rather than its floor — and was
  stopped at 24% battery rather than draining the machine overnight. A shorter
  6-point sweep aborted immediately because the adapter had been reconnected.

**To close it:**

```sh
# On battery, adapter unplugged, machine otherwise idle. Takes 20-45 minutes.
sudo ./.build/release/stressd calibrate --dwell 60s --cooldown 60s \
  --json > docs/power-curve-m3pro.json
```

`sudo` gives package power on top of battery draw, which is what makes the
"other" figure (display, radios, storage) derivable. Without it the curve is
still useful — battery draw is whole-system — just less decomposed.

Use a dwell of at least 45 s: the battery value updates slowly, so a 30 s dwell
may capture only one or two distinct readings per point.

Once a curve exists it is cached at `~/.config/stressd/power-curve.json` and
the `--target-watts` governor seeds its gain from it instead of guessing.

---

## 3. The `.powerDraw` governor on hardware

**Needs:** a power reading, so battery or root.

The control loop is implemented and unit tested against a simulated machine
that draws 10 W idle and 20 W more at full load; it converges to within 1.5 W
of a 30 W target. It has never run against real watts.

**To close it:** after producing a curve, on battery:

```sh
./.build/release/stressd run --target-watts 25 --duration 10m
```

Watch whether it settles, and whether the slew limit and deadband are right for
a signal that updates as slowly as the battery one does. My suspicion, stated
as suspicion: the 0.75 W deadband is probably too tight for a value that only
moves every 30 seconds, and the loop may sit still when it should be moving.

---

## 4. Live BOINC

**Needs:** an administrator password, and a project account.

`brew install --cask boinc` was attempted. It downloads a **manual installer**:
the cask expands a `.pkg` that has to be run by hand and requires admin rights.
It was uninstalled again rather than left half-installed.

Running the client without installing was also attempted — the `boinc` binary
extracted from the package refuses to start outside its expected ownership,
with error `-1005` and then `-1032` even under `--insecure`.

So `BOINCSource` is tested against **hand-written fixtures** for 7.x and 8.x
XML, not against output captured from a live client. The fixtures follow the
documented element shapes, but they are my reconstruction.

**To close it:**

```sh
brew install --cask boinc
open "/opt/homebrew/Caskroom/boinc/*/BOINC Installer.app"   # needs admin
# Attach to a project from BOINC Manager, then:
./.build/release/stressd sources
./.build/release/stressd run --cpu 80          # watch the mixer top up
```

The thing worth watching is the mixer absorbing a workunit boundary: synthetic
load should back off as BOINC ramps, with no visible oscillation.

Also untested live: writing `global_prefs_override.xml`. On a real install the
data directory is owned by `boinc_master`, so stressd will most likely find it
unwritable and fall back to run-mode control. That path is implemented and
reported in `stressd sources`, but which branch a real install takes is
unconfirmed.

---

## 5. Live Folding@home

**Needs:** an administrator password.

Folding@home is the one client that folds anonymously with no account, which is
why it was the preferred target for validating the mixer against real
contributed work. `fah-client` is not available as a Homebrew cask, and the
official installer is a `.pkg` that installs a launchd daemon and needs admin
rights.

`FoldingSource` is written against the documented v8 local API and tested
against fixtures including truncated and non-JSON input.

**To close it:** install the v8 client from
<https://foldingathome.org/start-folding/>, then:

```sh
./.build/release/stressd sources          # should detect it via the API
./.build/release/stressd run --cpu 70
```

No account is needed to fold. A passkey from
<https://apps.foldingathome.org/getpasskey> collects credit if wanted.

---

## 6. Live mlucas

**Needs:** a GIMPS account for work assignments.

`brew install mlucas` needs no admin rights, but the client does nothing
without assignments, and assignments need an account at mersenne.org.

`MlucasSource` parses `worktodo.ini` and the status file format, tested against
fixtures including a truncated status line.

**To close it:** get assignments from
<https://www.mersenne.org/manual_assignment/>, write them to
`~/Library/Application Support/stressd/mlucas/worktodo.ini`, then
`stressd run --cpu 60`.

---

## 7. Does Low Power Mode change the timer coalescing window?

**Needs:** `sudo` to toggle Low Power Mode.

The efficiency-core duty cycle period is derived from a measured coalescing
window. If Low Power Mode changes that window, the period must be re-measured
when the power state changes — and that is a live bug today, because nothing
currently triggers a re-measurement.

`PeriodPolicy.invalidate()` exists precisely for this, and is wired to be
callable, but nothing calls it because there is no evidence it is needed.

**To close it:**

```sh
sudo pmset -a lowpowermode 1
swift Tools/measure-timer-coalescing.swift    # compare the .background row
sudo pmset -a lowpowermode 0
```

If the window moves materially, wire `PeriodPolicy.invalidate()` to a power
source notification.

---

## 8. Core placement from an interactive session

**Needs:** running a script from a normal Terminal window.

Late measurements showed `.userInteractive` threads landing almost entirely on
efficiency cores, which contradicts how placement was described earlier in the
project. See [docs/mechanisms.md §3](docs/mechanisms.md). All measurements
tonight were taken from a shell spawned by an automation harness, and I could
not rule out a task-level scheduling role affecting the result.

**To close it:** from an ordinary Terminal window, machine otherwise idle:

```sh
swift Tools/measure-core-placement.swift
```

If `.userInteractive` threads fill cpu6–11 there, the earlier description was
right and the harness was the problem. If they fill cpu0–5 as they did tonight,
then macOS fills efficiency cores first regardless of QoS, and the
documentation is correct as it now stands.
