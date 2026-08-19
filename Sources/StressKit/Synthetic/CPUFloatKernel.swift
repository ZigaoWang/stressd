import Foundation

/// Dense FP64 fused multiply-add, sized to saturate an Apple silicon core's
/// floating point pipelines.
///
/// ## The recurrence
///
/// Each of seven independent pairs advances by a symplectic rotation:
///
///     x -= s * y
///     y += s * x        (using the updated x)
///
/// with `s = 0.001`. As a map, that is `[[1, -s], [s, 1 - s²]]`, whose
/// determinant is exactly 1 and whose trace is `2 - s²`. A trace strictly
/// between -2 and 2 puts both eigenvalues on the unit circle, so the state
/// rotates around an ellipse forever: bounded for any number of iterations, no
/// overflow, no denormals, and — unlike a contraction — never settling on a
/// constant the hardware could coast through.
///
/// ## Why this shape
///
/// Both statements are `self = self + a * b`, which compiles to `fmla` writing
/// into its own accumulator. That matters: the obvious formulation
/// `x = c + x * m` needs the destination seeded with `c` first, and measured on
/// an M3 Pro it emitted two `mov.16b` for every `fmla` and ran at 17.3 GFLOPS
/// against this version's 40.1 on the same core. The rotation form has no moves
/// at all.
///
/// Seven pairs of `SIMD4<Double>` is 28 of the 32 NEON registers, leaving room
/// for the two constants. Each pair is a two-deep dependency chain, so seven of
/// them in flight is what keeps four FP pipes at roughly four cycle FMA latency
/// fed. That is 28 `fmla.2d` per iteration, or 112 FLOPs.
///
/// Every pair starts from a different value. Identical pairs would be identical
/// subexpressions, and the optimiser would be entitled to collapse all seven
/// into one.
///
/// ## Why it cannot be optimised away
///
/// Floating point addition is not associative, so LLVM cannot reassociate the
/// chain, reduce the repeated rotation to a matrix power, or unroll a runtime
/// iteration count into a constant. Swift does not enable `-ffast-math`, which
/// is what would license any of that. The final state is written out through
/// `checksum`, which the worker stores into an atomic, giving the result an
/// escaping use so dead code elimination cannot remove the loop behind it.
///
/// ## How to verify that, rather than trust it
///
/// Both checks are in the test suite and both are cheap to re-run by hand:
///
/// 1. Timing scales with the iteration count. `CPUFloatKernelTests` asserts
///    that 4x the iterations takes between 3x and 5x the wall time in a release
///    build. A hoisted or folded loop would be flat.
///
///        swift test -c release --filter "scales linearly"
///
/// 2. The FMAs are really in the disassembly, inside a backward branch:
///
///        swift build -c release
///        otool -tV -p '_$s9StressKit14CPUFloatKernelV3run10iterationsySi_tF' \
///          .build/release/stressd | grep -c 'fmla.2d'
///
///    Expect 28, with no `mov.16b` between them.
public struct CPUFloatKernel: Sendable {

  /// Independent rotation pairs. Seven pairs of `SIMD4<Double>` occupy 28 NEON
  /// registers, the most that fits alongside the constants.
  public static let pairCount = 7

  /// FLOPs per iteration: 7 pairs x 2 statements x 4 lanes x (multiply + add).
  public static let flopsPerIteration = pairCount * 2 * 4 * 2

  /// Rotation angle per step. Small enough that the state moves smoothly and
  /// never approaches zero closely enough to denormalise, large enough that
  /// every step changes the value well above the noise floor.
  private static let step = SIMD4<Double>(repeating: 0.001)
  private static let negativeStep = SIMD4<Double>(repeating: -0.001)

  private var x0: SIMD4<Double>
  private var y0: SIMD4<Double>
  private var x1: SIMD4<Double>
  private var y1: SIMD4<Double>
  private var x2: SIMD4<Double>
  private var y2: SIMD4<Double>
  private var x3: SIMD4<Double>
  private var y3: SIMD4<Double>
  private var x4: SIMD4<Double>
  private var y4: SIMD4<Double>
  private var x5: SIMD4<Double>
  private var y5: SIMD4<Double>
  private var x6: SIMD4<Double>
  private var y6: SIMD4<Double>

  /// - Parameter seed: Offsets the starting state so concurrent workers do not
  ///   run bit-identical arithmetic. Has no effect on cost.
  public init(seed: UInt64 = 0) {
    // Distinct per pair and per lane, so no two chains are common
    // subexpressions.
    func start(_ index: Int) -> SIMD4<Double> {
      let base = 1.0 + Double(seed % 997) * 1e-6 + Double(index) * 0.011
      return SIMD4<Double>(base, base + 0.003, base + 0.006, base + 0.009)
    }
    x0 = start(0)
    y0 = start(1)
    x1 = start(2)
    y1 = start(3)
    x2 = start(4)
    y2 = start(5)
    x3 = start(6)
    y3 = start(7)
    x4 = start(8)
    y4 = start(9)
    x5 = start(10)
    y5 = start(11)
    x6 = start(12)
    y6 = start(13)
  }

  /// Advances every pair by `iterations` rotation steps.
  ///
  /// Not inlined, so the loop stays a single identifiable symbol for the
  /// disassembly check above.
  @inline(never)
  public mutating func run(iterations: Int) {
    guard iterations > 0 else { return }

    // Locals keep all 28 accumulators in vector registers for the whole loop
    // rather than round-tripping through `self` on every step.
    var a0 = x0
    var b0 = y0
    var a1 = x1
    var b1 = y1
    var a2 = x2
    var b2 = y2
    var a3 = x3
    var b3 = y3
    var a4 = x4
    var b4 = y4
    var a5 = x5
    var b5 = y5
    var a6 = x6
    var b6 = y6
    let s = Self.step
    let n = Self.negativeStep

    for _ in 0..<iterations {
      a0 = a0.addingProduct(b0, n)
      b0 = b0.addingProduct(a0, s)
      a1 = a1.addingProduct(b1, n)
      b1 = b1.addingProduct(a1, s)
      a2 = a2.addingProduct(b2, n)
      b2 = b2.addingProduct(a2, s)
      a3 = a3.addingProduct(b3, n)
      b3 = b3.addingProduct(a3, s)
      a4 = a4.addingProduct(b4, n)
      b4 = b4.addingProduct(a4, s)
      a5 = a5.addingProduct(b5, n)
      b5 = b5.addingProduct(a5, s)
      a6 = a6.addingProduct(b6, n)
      b6 = b6.addingProduct(a6, s)
    }

    x0 = a0
    y0 = b0
    x1 = a1
    y1 = b1
    x2 = a2
    y2 = b2
    x3 = a3
    y3 = b3
    x4 = a4
    y4 = b4
    x5 = a5
    y5 = b5
    x6 = a6
    y6 = b6
  }

  /// The accumulator state, reduced to one value.
  ///
  /// The worker stores this where the optimiser can see it escape, which is
  /// what keeps `run(iterations:)` alive.
  public var checksum: Double {
    let sum =
      ((x0 + y0) + (x1 + y1)) + ((x2 + y2) + (x3 + y3)) + ((x4 + y4) + (x5 + y5)) + (x6 + y6)
    var total = 0.0
    for lane in 0..<4 {
      total += sum[lane]
    }
    return total
  }

  /// The largest magnitude anywhere in the state. Used by tests to assert the
  /// rotation stays bounded.
  var peakMagnitude: Double {
    let vectors = [x0, y0, x1, y1, x2, y2, x3, y3, x4, y4, x5, y5, x6, y6]
    return vectors.reduce(0.0) { result, vector in
      max(result, (0..<4).reduce(0.0) { max($0, abs(vector[$1])) })
    }
  }

  /// FLOPs performed by `iterations` steps.
  public static func flops(forIterations iterations: Int) -> Double {
    Double(iterations) * Double(flopsPerIteration)
  }
}
