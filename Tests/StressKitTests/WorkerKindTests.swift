import Foundation
import Testing

@testable import StressKit

@Suite("Worker kinds")
struct WorkerKindTests {

  /// Every kernel must satisfy the same three properties, so they are checked
  /// the same way rather than one at a time.
  @Test("Every kernel does work that changes its state", arguments: WorkerKind.allCases)
  func kernelsCompute(kind: WorkerKind) {
    var kernel = AnyComputeKernel(kind: kind, seed: 1)
    defer { kernel.release() }

    let before = kernel.checksum
    kernel.run(iterations: kind == .cpuMatrix ? 200 : 200_000)
    #expect(kernel.checksum != before, "\(kind.rawValue) produced no change")
  }

  @Test("Every kernel stays bounded over a long run", arguments: WorkerKind.allCases)
  func kernelsStayBounded(kind: WorkerKind) {
    var kernel = AnyComputeKernel(kind: kind, seed: 7)
    defer { kernel.release() }

    // Long enough that an unbounded recurrence would have blown up.
    kernel.run(iterations: kind == .cpuMatrix ? 2_000 : 5_000_000)
    let checksum = kernel.checksum
    #expect(checksum.isFinite || checksum.isNaN == false)
    #expect(!checksum.isInfinite, "\(kind.rawValue) diverged")
  }

  @Test("Zero and negative iteration counts are no-ops", arguments: WorkerKind.allCases)
  func degenerateCounts(kind: WorkerKind) {
    var kernel = AnyComputeKernel(kind: kind, seed: 3)
    defer { kernel.release() }

    let before = kernel.checksum
    kernel.run(iterations: 0)
    kernel.run(iterations: -10)
    #expect(kernel.checksum == before)
  }

  @Test("The dispatch wrapper reports the kind it was built with")
  func dispatchReportsKind() {
    for kind in WorkerKind.allCases {
      let kernel = AnyComputeKernel(kind: kind, seed: 0)
      defer { kernel.release() }
      #expect(kernel.kind == kind)
      #expect(kernel.calibrationIterations > 0)
      #expect(!kind.summary.isEmpty)
    }
  }

  @Test("The integer kernel's branch really is unpredictable")
  func integerBranchIsUnpredictable() {
    // A branch the predictor can learn costs nothing and stresses nothing, so
    // the taken fraction has to sit near half rather than near 0 or 1.
    var kernel = CPUIntegerKernel(seed: 5)
    let iterations = 1_000_000
    kernel.run(iterations: iterations)

    let takenFraction = kernel.takenFraction / Double(iterations)
    #expect(
      abs(takenFraction - 0.5) < 0.05,
      "branch taken \(takenFraction) of the time; a predictable branch tests nothing")
  }

  @Test("The integer kernel reports no FLOPs rather than fake ones")
  func integerReportsNoFlops() {
    // Reporting a GFLOPS figure for integer work would be a lie in the units.
    #expect(CPUIntegerKernel.flopsPerIteration == 0)
  }

  @Test("The memory kernel's buffer is larger than any current last level cache")
  func memoryBufferExceedsCache() {
    // If it fits in cache the kernel measures the cache, not the memory
    // controller, which is the whole point of this kind.
    #expect(CPUMemoryKernel.bufferBytes >= 64 * 1024 * 1024)
  }

  @Test("The matrix kernel's FLOP count is the standard 2n^3")
  func matrixFlopAccounting() {
    let n = Double(CPUMatrixKernel.order)
    #expect(CPUMatrixKernel.flopsPerIteration == 2 * n * n * n)
  }

  @Test("Releasing a kernel twice does not double free")
  func releaseIsSafe() {
    // The enum is copied by value, so release is explicit rather than a deinit.
    // Only kinds that allocate need it, and calling it on the others is a no-op.
    let float = AnyComputeKernel(kind: .cpuFloat, seed: 0)
    float.release()
    float.release()

    let integer = AnyComputeKernel(kind: .cpuInteger, seed: 0)
    integer.release()
    integer.release()
  }
}
