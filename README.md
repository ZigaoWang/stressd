# stressd

**Stress testing that doesn't waste the work.**

Every stress tester on macOS burns cycles on garbage — synthetic loops whose
output goes straight to `/dev/null`. `stressd` runs real volunteer distributed
computing workloads as its load source instead. Same heat, same power draw, same
sustained pressure on the machine, except the FLOPs go to gravitational wave
searches and prime number hunts rather than nowhere.

Synthetic load is still there when you need it — as a fallback when no
contributed work is available, and as the precision instrument for holding an
exact utilization or wattage target. But the default is real work.

macOS 14+, Apple silicon only.

---

## Status

Under construction, built in stages. What exists today:

| | |
|---|---|
| `stressd topology` | ✅ shipped |
| `stressd watch` | in progress |
| `stressd calibrate` | planned |
| `stressd run` | planned |
| `stressd sources` | planned |

The sections below describe the parts that are built. The [roadmap](#roadmap)
covers the rest.

## Install

```sh
git clone https://github.com/zigaowang/stressd.git
cd stressd
swift build -c release
cp .build/release/stressd /usr/local/bin/
```

Requires Swift 6.0 or newer (Xcode 16+). Every command supports `--json`.

## Core topology

`stressd` reads the machine rather than assuming it. Nothing in the codebase
hardcodes a chip name, a core count, or even the number of core classes.

```
$ stressd topology

Machine
  Model           Mac15,6
  Chip            Apple M3 Pro
  Memory          18 GiB
  Cores           12 logical / 12 physical across 2 performance levels
  Cache line      128 B
  CPU index map   IORegistry device tree, clusters matched to performance levels by name

Performance levels (level 0 is fastest)

  Level 0  Performance
    Cores           6 logical / 6 physical
    Logical CPUs    6-11
    Cache           L1i 192 KiB   L1d 128 KiB   L2 16 MiB (shared by 6)
    QoS hint        .userInteractive

  Level 1  Efficiency
    Cores           6 logical / 6 physical
    Logical CPUs    0-5
    Cache           L1i 128 KiB   L1d 64 KiB   L2 4 MiB (shared by 6)
    QoS hint        .background

CPU features (53 present of 82 reported)
  AdvSIMD            AdvSIMD_HPFPCvt    arm64              armv8_1_atomics
  ...
```

Sources:

- `hw.nperflevels` for the number of core classes, handled generically — the
  code does not assume there are two.
- `hw.perflevelN.{name,logicalcpu,physicalcpu,l1icachesize,l1dcachesize,l2cachesize,cpusperl2}`
  for each class.
- `hw.optional.*` for architectural features, enumerated by walking the sysctl
  MIB rather than probing a hardcoded list, so a chip that adds `FEAT_` flags
  after this was written still reports them.
- The IORegistry device tree at `IODeviceTree:/cpus` for the logical CPU
  numbers belonging to each class.

### Why the device tree, and the trap it avoids

`hw.perflevelN` is ordered **fastest first**: `hw.perflevel0` is the
Performance level. The Mach logical CPU numbering used by
`host_processor_info` — and therefore by every per-core reading `stressd`
takes — is ordered the other way, **efficiency cores first**.

On an M3 Pro, `hw.perflevel0` is "Performance", but logical CPUs 0–5 are the
E-cores and 6–11 are the P-cores. Nothing in sysctl connects the two
numberings, and on parts where both levels have the same core count (M1, M3
Pro) you cannot even disambiguate them by size. Get it backwards and every
per-core utilization figure is silently attributed to the wrong core class.

So `stressd` resolves the mapping from `cluster-type` in the device tree, and
tells you which strategy produced it:

| Source | Meaning |
|---|---|
| `ioRegistryByClusterName` | Cluster type letter matched the level name (`P` → Performance) |
| `ioRegistryByCoreCount` | Cluster sizes were unambiguous |
| `ioRegistryByClusterOrder` | Matched by cluster ordering |
| `inferred` | Device tree unreachable; assumed slowest-numbered-first |

Only the last one is an assumption, and it says so.

### QoS is a hint, not affinity

macOS has **no public API for pinning a thread to a core class.** There is no
`pthread_setaffinity_np`, and `thread_policy_set` with an affinity tag is a
no-op on Apple silicon.

What `stressd` has is QoS, which biases the scheduler: `.userInteractive`
prefers P-cores, and `.background` is confined to E-cores. Neither is a
guarantee, and the scheduler is free to move work at any moment — under
thermal pressure or on battery it routinely does.

`stressd` treats this honestly. Wherever it acts on a placement hint, it also
reports the **observed** per-core utilization next to the **requested**
placement, so the gap between what was asked for and what happened is visible
rather than assumed away.

## Safety

Sustained full load on a Mac is a real thermal event, not a benchmark run.

- `stressd` backs off automatically at `ProcessInfo.ThermalState.serious` and
  stops entirely at `.critical`. This is a hard override and is not
  configurable.
- Fanless Macs (MacBook Air, base Mac mini) will hit thermal limits and stay
  there. Sustained maximum load on a passively cooled machine is not something
  to leave running unattended.
- Every source snapshots the state it modifies and restores it on exit,
  including on `SIGINT`, `SIGTERM`, and unexpected termination. If a BOINC or
  Folding@home client was already running before `stressd` started, it is left
  running afterwards.
- `stressd` never requires `sudo`. Package power telemetry is richer when it
  has elevated privileges, and simply reports `nil` when it does not.

## Roadmap

In build order:

1. ✅ Package scaffold, `CoreTopology`, `stressd topology`
2. `SyntheticSource` with duty-cycled CPU workers, per-core telemetry, `stressd watch`
3. Battery and power telemetry, `stressd calibrate`
4. `BOINCSource` and the synthetic top-up mixing logic
5. Power governor with a wattage target
6. Metal GPU worker
7. `FoldingSource`, `MlucasSource`, remaining worker kinds

### Planned load sources

**BOINC** (primary) — wraps `boinccmd`. Recommended projects:
[Einstein@Home](https://einsteinathome.org) (gravitational wave and pulsar
searches) and [PrimeGrid](https://primegrid.com) (prime number searches). Both
have native Apple silicon applications, including GPU apps.

**Folding@home** — wraps `fah-client` v8 over its localhost WebSocket API.

**GIMPS via mlucas** — note that Prime95/mprime is hand-written x86 assembly
and runs badly under Rosetta, which makes it useless as a load source here.
[mlucas](https://www.mersenneforum.org/mayer/README.html) is the correct GIMPS
client on Apple silicon.

**Synthetic** — the fallback and the precision instrument. Partial load is
implemented as duty cycling *inside every thread*, not by running fewer threads
than there are cores: a 50% target spreads across all cores rather than pinning
half of them, which gives a far more linear power curve and is much easier to
hold in a closed loop.

## Architecture

```
StressKit   library, all logic, no CLI code and no print statements
stressd     thin CLI wrapper
```

A SwiftUI menu bar app will link against `StressKit` later, so the library
stays free of any presentation concerns. `swift-argument-parser` is the only
dependency, and only the executable target sees it.

Everything that touches the system — sysctl, the IORegistry, subprocesses —
sits behind a protocol so the test suite runs against recorded fixtures from
machines that are not the one running the tests. `swift test` passes on any
Mac; the handful of tests that need real hardware skip themselves elsewhere.

## Contributing

```sh
swift build
swift test
swift format lint --recursive --strict Sources Tests Package.swift
```

CI runs all three on `macos-latest`, plus a release build, because the
synthetic workers are only meaningful when they survive optimisation.

## License

MIT. See [LICENSE](LICENSE).
