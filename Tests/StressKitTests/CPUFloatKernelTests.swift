import Foundation
import Testing

@testable import StressKit

@Suite("cpuFloat kernel")
struct CPUFloatKernelTests {

  @Test("The kernel actually changes state")
  func kernelComputes() {
    var kernel = CPUFloatKernel(seed: 1)
    let before = kernel.checksum
    kernel.run(iterations: 100_000)
    #expect(kernel.checksum != before)
  }

  @Test("The rotation stays bounded over a long run")
  func numericallyStable() {
    // The map is symplectic with unit determinant, so the state orbits rather
    // than growing or decaying. Over millions of iterations it must not reach
    // infinity, NaN, or the denormal range where FP64 throughput collapses.
    var kernel = CPUFloatKernel(seed: 7)
    kernel.run(iterations: 20_000_000)

    #expect(kernel.checksum.isFinite)
    #expect(!kernel.checksum.isNaN)
    #expect(
      kernel.peakMagnitude < 4.0,
      "state orbits near the unit circle; growth would mean the map is not stable")
    #expect(kernel.peakMagnitude > 0.01, "state should not have decayed towards zero")
  }

  @Test("The state keeps moving instead of settling on a constant")
  func neverConverges() {
    // A contraction would reach its fixed point and then compute the same value
    // forever, which is real work the hardware can coast through. A rotation
    // never does.
    var kernel = CPUFloatKernel(seed: 5)
    kernel.run(iterations: 10_000_000)
    let first = kernel.checksum
    kernel.run(iterations: 1_000)
    #expect(kernel.checksum != first)
  }

  @Test("Different seeds do different arithmetic")
  func seedsDiverge() {
    var first = CPUFloatKernel(seed: 1)
    var second = CPUFloatKernel(seed: 2)
    first.run(iterations: 10_000)
    second.run(iterations: 10_000)
    #expect(first.checksum != second.checksum)
  }

  @Test("Zero and negative iteration counts are no-ops")
  func degenerateIterationCounts() {
    var kernel = CPUFloatKernel()
    let before = kernel.checksum
    kernel.run(iterations: 0)
    kernel.run(iterations: -5)
    #expect(kernel.checksum == before)
  }

  @Test("FLOP accounting matches the kernel shape")
  func flopAccounting() {
    // Seven pairs of SIMD4<Double>, two FMAs each: 28 fmla.2d, which is 56
    // multiplies and 56 adds. Verified against the disassembly; see the doc
    // comment on CPUFloatKernel.
    #expect(CPUFloatKernel.pairCount == 7)
    #expect(CPUFloatKernel.flopsPerIteration == 112)
    #expect(CPUFloatKernel.flops(forIterations: 1_000) == 112_000)
  }

  /// The check that the loop survived the optimiser.
  ///
  /// Only meaningful in a release build, so it skips in debug rather than
  /// passing vacuously. Re-run by hand with:
  ///
  ///     swift test -c release --filter "scales linearly"
  ///
  /// A loop that had been hoisted, folded, or eliminated would take the same
  /// time regardless of the iteration count.
  @Test(
    "Work scales linearly with the iteration count, so the loop is really there",
    .enabled(if: BuildConfiguration.isRelease))
  func scalesLinearly() {
    func timeOf(iterations: Int) -> Double {
      var kernel = CPUFloatKernel(seed: 3)
      kernel.run(iterations: 200_000)  // warm up frequency and caches

      let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      kernel.run(iterations: iterations)
      let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start

      // Consume the result so this measurement cannot be optimised away either.
      #expect(kernel.checksum.isFinite)
      return Double(elapsed)
    }

    // Best of several runs: the minimum is the one least disturbed by whatever
    // else the machine was doing.
    let baseline = (0..<5).map { _ in timeOf(iterations: 1_000_000) }.min() ?? 0
    let quadruple = (0..<5).map { _ in timeOf(iterations: 4_000_000) }.min() ?? 0

    #expect(baseline > 0)
    let ratio = quadruple / baseline
    let detail =
      "4x the iterations took \(String(format: "%.2f", ratio))x the time; a value near 1 "
      + "would mean the loop was optimised away"
    #expect(ratio > 3.0 && ratio < 5.0, Comment(rawValue: detail))
  }
}

enum BuildConfiguration {
  static var isRelease: Bool {
    #if DEBUG
      return false
    #else
      return true
    #endif
  }
}
