# Measurements

Every empirical claim in this repository, with the method behind it.

## The one machine

| | |
|---|---|
| Model | MacBook Pro, `Mac15,6` |
| Chip | Apple M3 Pro, 6 performance + 6 efficiency cores, 18-core GPU |
| Memory | 18 GB unified |
| macOS | 26.6 (Darwin 25.6.0) |
| Toolchain | Swift 6.3.3, Xcode 26.6 |
| Power | AC, unless a row says battery |

**This is one machine running one OS version.** Nothing here has been
reproduced on another chip, another core configuration, or another macOS
release. Where a number is likely to move on other hardware, the row says so.

The machine was **not idle** for most of these runs: a normal desktop working
set (WindowServer, Spotlight, a browser, Figma) puts the baseline at 20–45%.
Every utilization figure is a delta over a baseline captured immediately
before the run, and the baseline is quoted where it matters.

Reproduce with the scripts in [`Tools/`](../Tools). One script per
measurement; each prints a table you can paste into a pull request.

---

## Timer coalescing

`Tools/measure-timer-coalescing.swift` · single run · median of 120 samples per
cell

Median overshoot on a requested 2.5 ms `mach_wait_until`:

| QoS | default | latency tier 0 |
|---|---:|---:|
| `.userInteractive` | 638 µs | 325 µs |
| `.utility` | 7 654 µs | 324 µs |
| `.background` | 77 635 µs | 329 µs |

Core placement, six `.background` threads at 50% duty, 2.5 s sample after a
1.5 s settle:

| latency tier | overshoot | E-cores | P-cores |
|---|---:|---:|---:|
| default | 76 880 µs | 58% | 14% |
| tier 0 | 324 µs | 46% | 62% |
| tier 1 | 629 µs | 50% | 71% |
| tier 2 | 1 253 µs | 41% | 57% |
| tier 3 | 8 857 µs | 60% | 30% |

The measured `.background` window has varied between runs: **62 ms and 77 ms**
on two nights on the same machine. This is why stressd measures it at startup
rather than hardcoding a period.

**Not measured:** whether Low Power Mode changes the window. Toggling LPM needs
administrator rights. `PeriodPolicy.invalidate()` exists so the period can be
re-measured on a power state change, but the need for it is unconfirmed. See
[DEFERRED.md](../DEFERRED.md).

---

## Duty cycle accuracy

`stressd run --cpu N --duration 3m` · one run per point · 1 Hz sampling ·
baseline ~30%

| requested | worker-measured | drift, final 90 s | abandoned cycles |
|---|---:|---:|---:|
| 25% | 25.31% | 0.14 points | 0 |
| 50% | 50.42% | 0.04 points | 0 |
| 75% | 75.65% | 0.07 points | 0 |

"Worker-measured" is busy time over elapsed time recorded inside the worker
loops, which excludes everything else on the machine. Shorter 10–20 second runs
on a busier machine land within about 1 point.

Period sweep, six `.background` threads, no latency tier, single run:

| period | duty at 25% request | duty at 50% request | P-cores at 50% |
|---|---:|---:|---:|
| 5 ms | 4.5% | 12.3% | 13.4% |
| 20 ms | 11.0% | 24.6% | 13.4% |
| 50 ms | 19.5% | 39.8% | 19.8% |
| 100 ms | 25.0% | 49.8% | 11.3% |
| 200 ms | 24.8% | 50.1% | 14.9% |

---

## Sampler validation against `top`

`stressd watch --json` and `top -l 2 -n 0` in the same window · single run

| | stressd | `top` |
|---|---:|---:|
| idle | 68.0% | 69.4% |
| user | 18.5% | 18.1% |
| system | 13.0% | 12.3% |

Under a 50% synthetic load:

| | stressd | `top` |
|---|---:|---:|
| idle | 25.0% | 26.4% |
| user | 62.5% | 61.5% |
| system | 12.5% | 12.1% |

---

## CPU kernel throughput

Single P-core, release build, best of 5 runs of 20 M iterations.
**Estimates from a counted FLOP-per-iteration figure, not benchmark scores.**

| kernel shape | NEON registers | GFLOPS FP64 |
|---|---:|---:|
| `c + x·m` form (rejected) | 16 + moves | 17.3 |
| 2 pairs × SIMD4 | 8 | 13.6 |
| **7 pairs × SIMD4 (shipping)** | 28 | **39.0** |
| 10 pairs × SIMD2 | 20 | 32.8 |

The rejected form emitted two `mov.16b` per `fmla`; the shipping rotation form
emits none.

Whole machine, all 12 cores, `stressd run --cpu 100`, single run each:

| kind | GFLOPS estimate | notes |
|---|---:|---|
| `cpuFloat` | 169.6–184.6 | FP64 through NEON |
| `cpuMatrix` | 332.9 | FP64 through Accelerate |
| `cpuInteger` | — | reports no FLOPs by design |
| `cpuMemory` | 0.4 | bandwidth bound, FLOPs are not the unit |

`cpuFloat` varied between 169.6 and 184.6 across runs on a machine with a
live desktop working set. Treat the spread as the measurement noise floor.

### Accelerate `dgemm`

Single calling thread, warm, single run:

| order | GFLOPS FP64 |
|---|---:|
| 32 | 192.1 |
| 64 | 297.8–309.3 |
| 128 | 375.1 |
| 256 | 393.6 |

At n=64, one calling thread consumed **1.78 cores** of CPU time (utilization
delta 14.9% of 12 cores, measured against a 19.9% baseline) while delivering
309.3 GFLOPS. That is ~174 GFLOPS per core-second against a NEON FP64 ceiling
near 65, so a different execution resource is in play — see
[mechanisms.md §7](mechanisms.md#7-cpumatrix-reaches-an-execution-resource-neon-cannot)
for why "it is AMX" is inferred rather than verified.

---

## GPU

`stressd run --gpu 100`, 22-second runs, single run each. Threadgroup geometry
selected by the startup benchmark: **64 threads × 4096 groups**.

| configuration | CPU GFLOPS | GPU GFLOPS |
|---|---:|---:|
| CPU 100% alone | 184.6 | — |
| GPU 100% `mixed` alone | — | 438.8 |
| both, GPU `mixed` | 153.6 | 433.8 |
| GPU 100% `bandwidth` alone | — | 11.7 |
| both, GPU `bandwidth` | 133.8 | 11.7 |

GPU figures are FP32 estimates from a counted FLOP-per-iteration figure. The
`bandwidth` profile's low number is expected: its unit of work is a memory
access, not a FLOP.

Running the GPU costs the CPU **17%** of its throughput with the `mixed`
profile and **28%** with `bandwidth`. The GPU loses ~1% and 0% respectively.

---

## Battery

Read from `AppleSmartBattery` in the IORegistry plus `IOPSCopyPowerSourcesInfo`.

Sign convention, verified in both directions on hardware:

| state | `InstantAmperage` | watts |
|---|---:|---:|
| charging on AC | +3182 mA at 11593 mV | **+36.9 W** |
| discharging, idle | — | **−25.94 W** |
| discharging, 100% CPU load | — | **−34.97 W** |

**Negative watts means discharging.**

Two observations that changed the design:

1. **The value is stale, not noisy.** Over 39 seconds of 1 Hz sampling it
   changed exactly once — cleanly, from −25.94 to −34.97 W, when load started.
   The 5-sample rolling median lagged that transition by 2 samples, as expected
   for a 5-wide window. The specification anticipated sample-to-sample noise;
   what is actually there is a slow update rate. Dwell times for calibration
   need to account for that.
2. **The OS percentage and the raw one disagree**: 25% reported against 24.0%
   raw (`AppleRawCurrentCapacity / AppleRawMaxCapacity`) on the same read. Both
   are reported, labelled.

`InstantAmperage` encodings seen in the wild: this machine's
`MaximumDischargeCurrent` holds `18446744073709544924`, the 64-bit unsigned
form of −6692. Reading it as `Int64` restores the sign for free. The 32-bit
widened form (e.g. `4294960604` for the same current) needs 2³² subtracted, and
is handled separately.

---

## Power curve

**Not measured.** Producing one needs battery for whole-system draw, and root
for package power. Two attempts were made:

- A full 11-point sweep on battery ran for over 40 minutes against a 24-minute
  estimate — sustained load held the thermal state at `.fair`, so every
  cooldown ran to its cap instead of its floor — and was stopped at 24%
  battery rather than draining the machine overnight.
- A shorter 6-point sweep aborted immediately because the adapter had been
  reconnected.

The `worstCaseSeconds` figure now reported at sweep start exists because of the
first attempt. See [DEFERRED.md](../DEFERRED.md) for how to produce a real
curve.

---

## Sanitizers

Full suite, 227 tests, including the threaded load paths:

| sanitizer | result |
|---|---|
| ThreadSanitizer | clean, no data races |
| AddressSanitizer | clean |

Load-magnitude assertions are skipped when a sanitizer is detected, because
instrumentation slows the kernels by roughly an order of magnitude. The
scheduling, park/unpark and lifecycle tests still run under both.
