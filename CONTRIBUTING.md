# Contributing

The most useful contributions to this project are **a new load source**, **a
new worker kind**, and **a column in the measurement tables from hardware that
is not an M3 Pro**. All three are deliberately easy; this document walks
through each.

## Ground rules

- `swift build -c release` clean, `swift format lint --strict` clean, tests
  green.
- New behaviour comes with a test. Tricky parts get thorough tests; obvious
  parts do not need ceremonial ones.
- **Never fake a measurement.** If something is not verified on hardware, say
  so in the doc comment and add it to `DEFERRED.md`. A claim marked "inferred"
  is worth more than one that is wrong.
- Comments explain *why*, not *what*. The code already says what.

```sh
swift build
swift test                                   # includes load-generating tests
STRESSD_SKIP_INTEGRATION_TESTS=1 swift test  # unit tests only
swift format lint --recursive --strict Sources Tests Package.swift
```

---

## Adding a `LoadSource`

A load source is anything that can put work on the machine. `BOINCSource`
contributes real work; `SyntheticSource` does not. The protocol is small:

```swift
public protocol LoadSource: Sendable {
  var id: String { get }
  var isContributing: Bool { get }

  func detect() async -> DetectionResult
  func start(budget: ResourceBudget) async throws
  func adjust(to budget: ResourceBudget) async throws
  func stop() async
  func status() async throws -> SourceStatus
}
```

### Worked example: a source wrapping a hypothetical `foocrunch` client

```swift
public actor FooCrunchSource: LoadSource {
  public nonisolated let id = "foocrunch"
  public nonisolated let isContributing = true

  // Inject the subprocess runner. This is what lets the tests run in CI on a
  // machine that has never heard of foocrunch.
  private let runner: any CommandRunning
  private var requestedLoad: Double = 0

  public init(runner: any CommandRunning = SubprocessRunner()) {
    self.runner = runner
  }

  public func detect() async -> DetectionResult {
    guard let path = Self.locate() else {
      return .unavailable(
        reason: "foocrunch not found",
        // Install hints are copy-pasteable commands, not prose.
        installHint: "brew install foocrunch")
    }
    // Distinguish "installed" from "installed and running": the fix differs.
    guard (try? runner.run(path, arguments: ["--ping"]))?.succeeded == true else {
      return .unavailable(
        reason: "foocrunch is installed but not responding",
        installHint: "brew services start foocrunch")
    }
    return .available(detail: "foocrunch at \(path)")
  }

  public func start(budget: ResourceBudget) async throws {
    // Snapshot anything you are about to change, BEFORE changing it, and
    // persist the snapshot to disk. A SIGKILL runs no cleanup handlers, and
    // the on-disk record is the only thing that can repair the machine on the
    // next launch. See BOINCRestoreStore.
    requestedLoad = budget.cpu
    try apply(budget.cpu)
  }

  public func adjust(to budget: ResourceBudget) async throws {
    // Called about once a second by the mixer. Make this cheap, and do not
    // tear anything down. If your client can only be reconfigured by
    // restarting it, say so in the doc comment rather than hiding it, as
    // MlucasSource does.
    guard abs(budget.cpu - requestedLoad) > 0.01 else { return }
    requestedLoad = budget.cpu
    try apply(budget.cpu)
  }

  public func stop() async {
    // Restore exactly what you found. If a file did not exist, delete the one
    // you created rather than leaving an empty one behind.
  }

  public func status() async throws -> SourceStatus {
    SourceStatus(
      sourceID: id, isContributing: true, state: .running,
      requestedLoad: requestedLoad,
      // Free-form, shown by `stressd watch`. Use "idleReason" when the client
      // has no work: the mixer needs to know so synthetic load can take over,
      // and the user needs to know so it does not look like they contributed.
      detail: ["project": "Foo", "idleReason": "no work downloaded"])
  }
}
```

### What reviewers will look for

1. **Detection distinguishes missing from stopped.** Different fix, different
   hint.
2. **Restore is exact and crash-safe.** Snapshot before mutating, persist the
   snapshot, repair on next launch.
3. **`adjust` is cheap**, and if it cannot be, that is documented.
4. **Parsing is defensive.** Missing fields are `nil`, unknown fields are
   ignored and logged once, and truncated input fails loudly rather than
   looking like an empty result. A half-read document that parses as "no work"
   will make the mixer take over the whole target.
5. **Tests use a mock runner.** See `MockCommandRunner` in the test target.

Then add it to `SourcesCommand` and, if it should participate in mixing, to
`RunCommand`.

---

## Adding a `WorkerKind`

A worker kind is a compute kernel the synthetic source can run. The existing
ones stress different parts of the package on purpose: FP pipelines, branch
prediction, the memory controller, the matrix unit.

```swift
public protocol ComputeKernel {
  static var flopsPerIteration: Double { get }
  mutating func run(iterations: Int)
  var checksum: Double { get }
}
```

### The three properties a kernel must have

1. **Work is proportional to `iterations`.** The duty cycler sizes chunks from
   a measured rate; a kernel whose cost per iteration varies wildly will make
   the duty cycle noisy.
2. **State is bounded for any iteration count.** No overflow, no denormals, and
   crucially **no settling on a constant** — a converged recurrence is work the
   hardware can coast through. `CPUFloatKernel` uses a symplectic rotation
   because its map has unit determinant, so the state orbits forever.
3. **The result escapes.** `checksum` must be read by the worker, or the
   optimiser deletes the loop and you have a stress tester that stresses
   nothing.

### Worked example

```swift
public struct CPUCryptoKernel: ComputeKernel, Sendable {
  // If your unit of work is not a FLOP, report zero rather than inventing a
  // number. A GFLOPS figure for hashing is a lie in the units.
  public static let flopsPerIteration: Double = 0

  private var state: SIMD4<UInt64>

  public init(seed: UInt64 = 0) {
    state = SIMD4(0x243F_6A88 &+ seed, 0x85A3_08D3, 0x1319_8A2E, 0x0370_7344)
  }

  @inline(never)                       // keep it one symbol for disassembly
  public mutating func run(iterations: Int) {
    guard iterations > 0 else { return }
    var local = state                  // keep it in registers
    for _ in 0..<iterations {
      local = mix(local)               // wrapping arithmetic: bounded for free
    }
    state = local
  }

  public var checksum: Double {
    Double(bitPattern: (state[0] ^ state[1] ^ state[2] ^ state[3]) | 1)
  }
}
```

Then add a case to `WorkerKind` and to `AnyComputeKernel` — an enum rather than
an existential, so the hot loop has no witness-table call. Give it a
`calibrationIterations` value in the right order of magnitude: a `dgemm`
iteration is roughly a million times the work of an integer one.

### Prove it survived the optimiser

Two checks, both already in `CPUFloatKernelTests`:

```sh
# Wall time scales with iteration count. A folded loop is flat.
swift test -c release --filter "scales linearly"

# The instructions are really there, inside a backward branch.
swift build -c release
otool -tV -p '_$s9StressKit14CPUFloatKernelV3run10iterationsySi_tF' \
  .build/release/stressd | grep -c 'fmla.2d'
```

---

## Adding a hardware column

This is the highest-value contribution and takes about ten minutes. Every
measurement in `docs/measurements.md` comes from **one M3 Pro**, which is not a
survey.

```sh
swift Tools/measure-timer-coalescing.swift   # the coalescing window and placement
swift Tools/measure-core-placement.swift     # where threads actually land
./.build/release/stressd topology --json     # the topology as detected
```

Open a pull request adding your column, with the exact chip, exact macOS
version, and whether the machine was idle. If a number contradicts the M3 Pro
one, that is the most useful possible outcome — say so plainly and we will fix
the claim.
