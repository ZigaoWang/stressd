# stressd

**Stress testing that doesn't waste the work.**

macOS 14+, Apple silicon. Written in Swift.

---

## The finding that shaped this project

macOS coalesces timer wake-ups, and how aggressively depends on the thread's
QoS class. Measured on an M3 Pro running macOS 26.6 — median overshoot on a
requested **2.5 ms** `mach_wait_until`:

| QoS class | default | with latency tier 0 |
|---|---:|---:|
| `.userInteractive` | 638 µs | 325 µs |
| `.utility` | 7 654 µs | 324 µs |
| `.background` | **77 635 µs** | 329 µs |

A duty cycler built on a 5 ms period cannot survive a 77 ms overshoot. That is
what a `.background` worker was really doing: 2.5 ms of work, then an 80 ms
sleep — about **3% duty against a 50% request**.

The obvious fix is `THREAD_LATENCY_QOS_POLICY`. It works, and it costs you the
thing you asked for: every latency tier precise enough to matter also lifts the
thread off the efficiency cores.

| latency tier | overshoot | E-cores | P-cores |
|---|---:|---:|---:|
| default | 76 880 µs | 58% | 14% |
| tier 0 | 324 µs | 46% | **62%** |
| tier 3 | 8 857 µs | 60% | 30% |

So stressd does neither. It **measures the coalescing window at startup** and
sets the duty cycle period to `max(measured × 1.5, 50 ms)`. The window is not a
constant — it measured 62 ms one night and 77 ms another on the same machine —
so deriving the period beats hardcoding it. Efficiency workers hold their
target *and* stay on the efficiency cores.

Full reasoning, including which parts are measured and which are inferred, is
in [docs/mechanisms.md](docs/mechanisms.md).

---

## The pitch

Every stress tester on macOS burns cycles on garbage — synthetic loops whose
output goes to `/dev/null`. stressd runs real volunteer distributed computing
workloads as its load source instead. Same heat, same power draw, same
sustained pressure, except the FLOPs go to gravitational wave searches and
prime hunts rather than nowhere.

Synthetic load remains, as the fallback when no contributed work is available
and as the precision instrument for holding an exact target.

```sh
stressd run --cpu 80          # contributed work first, synthetic tops up
stressd run --cpu 50 --gpu 40
stressd watch                 # live telemetry, no load
stressd topology              # what the machine actually is
stressd sources               # what is installed, and how to install the rest
stressd calibrate             # sweep load, record power, emit a curve
```

Every command supports `--json`.

---

## What works, and how well

**Duty cycle accuracy.** Three-minute runs, 1 Hz sampling, on a machine with a
~30% baseline:

| requested | worker-measured | drift over final 90 s | abandoned cycles |
|---|---:|---:|---:|
| 25% | 25.31% | 0.14 points | 0 |
| 50% | 50.42% | 0.04 points | 0 |
| 75% | 75.65% | 0.07 points | 0 |

Partial load is duty cycling **inside every thread**, not fewer threads. A 50%
target runs every core at 50%, which keeps the power curve closer to linear and
leaves a closed-loop governor a single scalar to move.

**Reads the machine, never assumes it.** `hw.nperflevels` for the number of
core classes, handled for any N. `hw.perflevelN` for sizes and caches. The
`hw.optional` MIB walked rather than probed, so a chip that adds `FEAT_` flags
after this was written still reports them.

**The CPU numbering trap.** `hw.perflevelN` is ordered fastest-first;
`host_processor_info`'s logical CPU numbering is ordered efficiency-first. On
an M3 Pro `hw.perflevel0` is "Performance" but logical CPUs 0–5 are E-cores.
Nothing in sysctl connects them, and on parts where both levels have equal core
counts (M1 4+4, M3 Pro 6+6) size cannot disambiguate them either. stressd
resolves the mapping from `cluster-type` in the IORegistry device tree,
validates it is a bijection over `0..<hw.logicalcpu`, and tells you which
strategy produced it.

**Four CPU kernels and three GPU profiles**, because "CPU load" is not one
thing: `cpuFloat` (NEON FP64), `cpuInteger` (unpredictable branches),
`cpuMemory` (bandwidth bound), `cpuMatrix` (Accelerate). GPU: `alu`,
`bandwidth`, `mixed`, with the threadgroup geometry benchmarked at launch.

**Contributed sources**: BOINC, Folding@home, mlucas — the last because
Prime95's inner loops are hand-written x86 assembly and run under Rosetta on
Apple silicon, which makes it the wrong GIMPS client here.

**The mixer** holds a total target by topping contributed load up with
synthetic load every second, with a slew limit and a deadband so it does not
oscillate against BOINC's sharp workunit boundaries.

---

## Honest limits

**One machine.** Every number here comes from a single MacBook Pro (`Mac15,6`,
M3 Pro, 6P+6E) on macOS 26.6. Not a survey. See
[docs/measurements.md](docs/measurements.md) for method and sample sizes;
several figures are from a single run and say so.

**Support matrix:**

| Chip | Status |
|---|---|
| M3 Pro (6P+6E) | Real hardware. Every measurement here. |
| M1, M2 Pro, M3 Pro, M4 Max | Topology **fixtures only** — parsing is tested, nothing was run |
| Anything else Apple silicon | Should work. Topology is read generically, for any number of performance levels |
| Unknown `cluster-type` | Falls back to an inferred CPU map and **says so** in `stressd topology` |
| Intel Mac | Not supported |

**GFLOPS figures are estimates**, computed from a counted FLOP-per-iteration
figure. They are not benchmark scores and should not be compared against one.

**Not validated on hardware:** the `.powerDraw` governor, live BOINC,
Folding@home and mlucas, and a real power curve. All are implemented and
tested against fixtures. [DEFERRED.md](DEFERRED.md) lists each one with the
exact command to close it.

**A correction.** Earlier versions of this README claimed `.userInteractive`
biases work onto performance cores. Late measurement did not support that: six
such threads filled cpu0–5 (the E-cores) and left the P-cores idle. What is
verified is the *other* direction — `.background` is confined to E-cores. See
[docs/mechanisms.md §3](docs/mechanisms.md), which also says what is still
unresolved about it.

---

## Compared with stress-ng

Measured with stressd's own methodology — delta over a baseline captured
immediately before load, on a machine with a live desktop working set.

`stress-ng --cpu 12` and `stressd run --cpu 100` both drive the machine to
saturation; on a busy host neither can be distinguished from the other by total
utilization alone.

Where they differ:

- **stress-ng cannot hold a partial target.** `--cpu-load 50` exists, but it is
  a per-worker busy/idle split with no closed loop, so what you get depends on
  what else the machine is doing. stressd measures utilization every second and
  corrects.
- **stress-ng has vastly more stressors** — over 300 — covering filesystem,
  network, syscalls and much else. stressd has seven. For anything other than
  CPU/GPU heat, use stress-ng.
- **stress-ng is portable and mature.** stressd is macOS-only and new.

If you want a general-purpose stressor, use stress-ng. stressd is for holding a
*specific* load or wattage on Apple silicon, and for not wasting the work.

---

## Install

```sh
git clone https://github.com/ZigaoWang/stressd.git
cd stressd
swift build -c release
cp .build/release/stressd /usr/local/bin/
```

Requires Swift 6.0+ (Xcode 16+).

## Safety

Sustained full load on a Mac is a real thermal event, not a benchmark run.

- stressd backs off at `ProcessInfo.ThermalState.serious` and stops at
  `.critical`. **This is a hard override and is not configurable.** A stress
  tester that lets you disable its own thermal protection is one that cooks a
  laptop.
- Fanless Macs will reach thermal limits and stay there.
- Every source snapshots what it modifies and restores it on exit, including
  `SIGINT`, `SIGTERM`, and an unclean kill — BOINC's `global_prefs_override.xml`
  is journalled to disk before it is touched, and repaired on the next launch.
- stressd never requires `sudo`. Package power is richer with it and simply
  `nil` without it.

## Documentation

- [docs/mechanisms.md](docs/mechanisms.md) — how it works, and what is verified
  versus inferred
- [docs/measurements.md](docs/measurements.md) — every empirical claim, with
  method and sample size
- [DEFERRED.md](DEFERRED.md) — what is not yet validated on hardware
- [CONTRIBUTING.md](CONTRIBUTING.md) — adding a `LoadSource` or a `WorkerKind`
- [Examples/](Examples) — a 30-line program that starts load and stops cleanly

## Provenance

The code was substantially written with Claude Code. The design decisions,
the measurements, and the validation are mine.

## License

MIT. See [LICENSE](LICENSE).
