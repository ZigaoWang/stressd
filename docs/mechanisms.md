# Mechanisms

How stressd works, and — more importantly — **which parts are measured and
which are inferred**. Every section is marked.

- **Verified** means measured on hardware, with the method and numbers in
  [measurements.md](measurements.md).
- **Documented** means Apple or another vendor states it.
- **Inferred** means a plausible explanation constructed to fit observed
  behaviour, without a source confirming the mechanism. Inferred sections say
  what evidence would settle them.

All measurements come from **one machine**: MacBook Pro (Mac15,6), Apple M3
Pro, 6P+6E, 18 GB, macOS 26.6 (Darwin 25.6.0), Swift 6.3.3. One machine and
one OS version is not a survey.

---

## 1. CPU index numbering runs opposite to performance levels

**Verified.**

`hw.perflevelN` is ordered fastest first: `hw.perflevel0` is the Performance
level. The Mach logical CPU numbering used by `host_processor_info` is ordered
the other way, efficiency cores first.

On the M3 Pro, `hw.perflevel0` is "Performance" while logical CPUs 0–5 are the
E-cores and 6–11 the P-cores. Confirmed directly from the IORegistry device
tree at `IODeviceTree:/cpus`, where `cluster-type` reads `E` for cpu0–5 and `P`
for cpu6–11.

Nothing in sysctl connects the two numberings, and on parts where both levels
have equal core counts (M1 4+4, M3 Pro 6+6) they cannot be told apart by size
either. stressd resolves the mapping from the device tree and reports which
strategy produced it.

**Inferred:** that the ordering (E-cores numbered first) holds on *all* Apple
silicon. It holds on the one machine measured and matches every published
teardown, but Apple does not document it. This is why it is only ever a
fallback, and why `stressd topology` prints `inferred` when it is used.

---

## 2. Timer coalescing sets a floor on the duty cycle period

**Verified — the behaviour. Inferred — the cause.**

### What is measured

Median overshoot on a requested 2.5 ms `mach_wait_until`, by QoS class:

| QoS | default | latency tier 0 |
|---|---:|---:|
| `.userInteractive` | 638 µs | 325 µs |
| `.utility` | 7 654 µs | 324 µs |
| `.background` | 77 635 µs | 329 µs |

A `.background` worker on a 5 ms period therefore does 2.5 ms of work and then
sleeps for 80 ms, which is about 3% duty against a 50% request. Measured
end-to-end: a 50% request produced 12.3% duty at a 5 ms period, 39.8% at 50 ms,
and 49.8% at 100 ms.

**The knee tracks the coalescing window, not a constant.** stressd measures the
window at startup and sets the period to `max(measured × 1.5, 50 ms)`. On this
machine the window measured 62 ms on one night and 77 ms on another, giving
periods of 93 ms and 100 ms respectively.

### What is documented

Apple documents timer coalescing as a power-saving feature and documents
`THREAD_LATENCY_QOS_POLICY` as a way to express latency requirements. The
`ProcessInfo` and `libdispatch` documentation describes QoS classes as
influencing timer leeway.

### What is inferred

**Why latency tier 0 also moves threads onto P-cores is inferred, not
verified.** The measurement is unambiguous:

| latency tier | overshoot | E-cores | P-cores |
|---|---:|---:|---:|
| default | 76 880 µs | 58% | 14% |
| tier 0 | 324 µs | 46% | 62% |
| tier 1 | 629 µs | 50% | 71% |
| tier 2 | 1 253 µs | 41% | 57% |
| tier 3 | 8 857 µs | 60% | 30% |

The plausible story is that the scheduler treats a low latency requirement as
incompatible with the E-cluster's wake latency and DVFS behaviour, and promotes
the thread. **I have not confirmed this from Apple documentation or XNU
source.** It is a story that fits five data points.

What would settle it: reading `thread_policy_set` handling of
`THREAD_LATENCY_QOS_POLICY` in the XNU sources, and whether the recommended-core
or cluster-binding logic consults `th_latency_qos`. Until then, treat "tier 0
promotes to P-cores" as a reliably reproducible *behaviour* and the reason for
it as unconfirmed.

stressd sidesteps the question: it uses a longer period instead of a latency
tier, which holds the duty cycle with no effect on placement.

---

## 3. QoS placement: P-cores fill first, and there is no ramp

**Verified by time series.** This section has been wrong twice; the current
version rests on seven runs rather than one.

macOS exposes no public API for pinning a thread to a core class. There is no
`pthread_setaffinity_np`, and `thread_policy_set` with
`THREAD_AFFINITY_POLICY` is documented as unsupported on Apple silicon. QoS is
the only lever, and it is a hint.

### What the hint actually does

`.userInteractive` threads are placed on **performance cores first**, and spill
to efficiency cores only once the P cluster is saturated. Per-second series,
120 seconds each, 12-core M3 Pro, baseline E≈33% P≈14%:

| threads | P-cores | E-cores |
|---|---|---|
| 6 | **93.5%**, flat across all five windows | ~30%, i.e. baseline |
| 12 | 99.7%, flat | 93.3% rising slowly to 96.3% |
| 18 | 100% | 99.9% |

Six threads is exactly the P-core count, and they fill it without touching the
E-cores. The staggered run makes the ordering unmistakable — twelve threads
spawned gradually over 30 seconds:

| window | threads running | P-cores | E-cores |
|---|---:|---:|---:|
| 0–10 s | 1→4 | 53.0% | 24.4% |
| 10–20 s | 4→8 | 92.5% | 30.8% |
| 20–30 s | 8→12 | 99.0% | 77.2% |
| 30–45 s | 12 | 99.7% | 95.2% |

E-core utilization sits at or below baseline until the P cluster is full, then
climbs. That is an ordered fill, not a preference for E.

`.background` remains confined to the efficiency cores, which is the other
half of the same story.

### There is no ramp, and short measurements are not biased

The reason this was measured as a series rather than a mean: a scheduler that
engages P-cores only after sustained saturation would make every short
measurement in this project read low, and the tables would need re-taking with
a stated settling window.

**That is not what happens.** With six threads, P-core utilization is 93.5% in
the very first ten-second window and 93.1% in the last, varying between 91.5%
and 97.9% across all 120 samples with no trend. There is no time constant to
find, and no settling window is required.

### The measurement I could not reproduce

One earlier run measured the opposite — six `.userInteractive` threads pinning
cpu0–5 (E) at 100% while cpu6–11 (P) sat near zero. I took that at face value
and rewrote this section and the README around it. That was a mistake: it was a
single 5-second sample, and it is now contradicted by seven runs.

Deliberate attempts to reproduce it all failed:

- **Thermal recovery**: measuring immediately after 90 seconds of sustained
  100% load gave P = 93.0%, unchanged.
- **Launch context**: run detached from a subshell, the way the outlier was
  launched, gave P = 94.8% against 96.1% in the foreground.
- **Machine load**: baseline varied from 26% to 57% across tonight's runs with
  no effect on the ordering.

I do not know what produced it. The honest reading is that it was a
contaminated or unlucky sample, and that the behaviour documented above is the
real one. It is recorded here rather than deleted because an unexplained
observation is worth more in the open than quietly dropped.

stressd always reports observed per-core utilization next to requested
placement, which is what made both the error and its correction visible.

Reproduce with `Tools/measure-core-placement.swift`, which emits the full
series rather than an average.

---

## 4. `mach_wait_until` oversleeps, and the error is one-sided

**Verified.**

Sleeps overshoot; they never undershoot. Measuring the work window from the
grid start therefore loses time systematically rather than symmetrically. An
early version did exactly that and produced 10.3% duty against a 25% request.

The fix is a work-debt model: the cycle boundary stays anchored at
`anchor + n × period`, which fixes the duty cycle's denominator, and the work
quantum is measured from when the worker actually arrives, which fixes the
numerator. After the fix, three-minute runs measured 25.31 / 50.42 / 75.65%
against 25 / 50 / 75% requests, with drift under 0.15 points across the final
90 seconds and zero abandoned cycles.

---

## 5. The compute kernels survive optimisation

**Verified.**

A stress tester whose loop is optimised away measures nothing. The FP64 kernel
uses a symplectic rotation, `x -= s·y; y += s·x`, whose map has unit
determinant and a trace strictly inside (−2, 2). Both eigenvalues sit on the
unit circle, so the state orbits indefinitely: bounded for any iteration count,
no overflow, no denormals, and never settling on a constant.

Two checks, both re-runnable:

1. Wall time scales with iteration count — 4× the iterations takes 3–5× the
   time in release. A folded loop would be flat.
2. The release disassembly contains 28 `fmla.2d` and zero `mov.16b` inside a
   backward branch.

**Inferred:** that LLVM *cannot* reduce the recurrence to a closed form. The
reasoning is that floating point addition is not associative and Swift does not
enable `-ffast-math`, so reassociation and matrix exponentiation are not
legal transformations. This is standard and I am confident in it, but it is an
argument from the language rules rather than a measurement. The disassembly
check is what actually verifies it, per build.

---

## 6. Register pressure, not chain depth, limits the FP64 kernel

**Verified.**

Each oscillator pair is a two-deep dependency chain, so throughput should scale
with pairs in flight until the FMA pipeline saturates. Measured on one P-core:

| shape | NEON registers | GFLOPS |
|---|---:|---:|
| 2 pairs × SIMD4 | 8 | 13.6 |
| 7 pairs × SIMD4 (shipping) | 28 | 39.0 |
| 10 pairs × SIMD2 | 20 | 32.8 |

28 of 32 NEON registers are already in use, so there is nowhere wider to go.
The shipping shape is the best of the three tested. At roughly 39–40 GFLOPS
against a NEON FP64 ceiling near 65 GFLOPS/core, about 60% of peak, the
remaining gap is the two-deep dependency inside each pair — which cannot be
removed without giving up the boundedness that makes the kernel safe to run
indefinitely.

---

## 7. `cpuMatrix` reaches an execution resource NEON cannot

**Verified as throughput. Inferred as to which resource.**

One thread calling `cblas_dgemm` at n=64 delivers **309 GFLOPS FP64** while
consuming **1.78 cores** of CPU time — roughly 174 GFLOPS per core-second,
against a NEON FP64 ceiling near 65 GFLOPS/core.

That is comfortably outside what NEON can do, so a different execution resource
is certainly involved. **That it is specifically the AMX matrix coprocessor is
inferred.** Accelerate exposes no flag saying which unit served a call, and AMX
is not a documented public interface.

What would settle it: CPU performance counters attributing the work to the
matrix unit, which needs elevated privileges, or Instruments' hardware counter
templates.

The 1.78-core figure also means Accelerate is doing some work off the calling
thread, so "single threaded" would be the wrong description.

**Also inferred:** that the matrix unit is shared per CPU cluster rather than
per core. Twelve `dgemm` threads deliver nowhere near twelve times one thread's
throughput, and the `cpuMatrix` advantage over `cpuFloat` shrinks from 2.0x on
a quiet machine to 1.4x on a busy one. Cluster-level sharing fits both
observations, but so would several other explanations, including simple memory
bandwidth limits.

---

## 8. GPU and CPU contend, asymmetrically

**Verified.**

On Apple silicon the GPU shares the memory controller with the CPU, so the
hypothesis was that running both flat out would not be additive. Measured,
22-second runs, throughput estimates:

| configuration | CPU GFLOPS | GPU GFLOPS |
|---|---:|---:|
| CPU 100% alone | 184.6 | — |
| GPU 100% (mixed) alone | — | 438.8 |
| both, GPU mixed | 153.6 (−17%) | 433.8 (−1%) |
| GPU 100% (bandwidth) alone | — | 11.7 |
| both, GPU bandwidth | 133.8 (−28%) | 11.7 (0%) |

Adding GPU load costs the CPU 17% of its throughput with the arithmetic-heavy
profile and 28% with the bandwidth-heavy one. **The GPU loses essentially
nothing in either case.** The contention is real, it is worse when the GPU
profile is memory-bound, and it is one-directional.

**Inferred:** that the mechanism is memory controller contention specifically,
rather than shared power budget or thermal headroom. The fact that the
bandwidth profile costs the CPU more than the ALU profile — while both keep
the GPU at 100% duty — points at memory rather than power, but these runs were
on AC with no package power measurement, so power cannot be ruled out.

What would settle it: the same matrix with package power from `powermetrics`,
which needs root, plus per-cluster power. That is in
[DEFERRED.md](../DEFERRED.md).

---

## 9. Restoring BOINC settings after an unclean exit

**Verified by construction and unit test; not verified against a live client.**

stressd writes `global_prefs_override.xml` to control BOINC's CPU share, which
means a crash could leave a user's preferences overwritten. That is the one
failure mode here that silently damages someone's configuration.

The design: before anything is modified, a journal holding the file's exact
original bytes and the permanent run mode is written to
`~/Library/Application Support/stressd/boinc-restore.json`. A clean stop
restores and clears it. An unclean exit leaves it, and the next launch finds it
and repairs the machine *before* taking a new snapshot — otherwise the new
snapshot would capture stressd's own settings as the user's.

Restoring a file that did not previously exist means deleting it, not writing
an empty one, which would silently override real preferences with nothing.

The `atexit` backstop is deliberately **not** the primary mechanism. `atexit`
handlers do not run on an uncaught signal, and they call code that is not
async-signal-safe. The on-disk journal is what actually makes this safe: it
requires no code to run at exit at all.

---

## 10. Utilization is measured differentially

**Verified.**

The development machine idles at 30–45% CPU from a normal desktop working set.
Absolute utilization numbers on such a machine describe the browser as much as
the tool.

`host_processor_info` per-CPU tick deltas are validated against `top` on the
same machine, same window: idle 68.0% vs 69.4%, user 18.5% vs 18.1%, system
13.0% vs 12.3%. Under a 50% load: 62.5 / 12.5 / 25.0 against top's
61.5 / 12.1 / 26.4.

Every sample asserts that user + system + nice + idle sums to exactly 1, which
catches a dropped or double-counted bucket — the class of bug that would
silently invert every reading.

`run` captures a baseline before starting and reports load as both absolute and
delta. `calibrate` subtracts a baseline from every point and warns above 15%.
