import Accelerate
import Foundation

/// Which compute kernel a synthetic CPU worker runs.
///
/// These exist because "CPU load" is not one thing. A core saturating its FP
/// pipelines, a core stalling on branches, and a core saturating the memory
/// controller draw different amounts of power and stress different parts of
/// the package. A stress tester with only one of them tests only one thing.
public enum WorkerKind: String, Sendable, Codable, CaseIterable {
  /// Dense FP64 fused multiply-add through NEON. The default.
  case cpuFloat
  /// Branch-heavy integer work. Different power profile: it exercises the
  /// branch predictor and integer units rather than the FP pipelines.
  case cpuInteger
  /// Streaming memory access, bound by bandwidth rather than by either
  /// execution unit.
  case cpuMemory
  /// Dense FP64 matrix multiply through Accelerate, which reaches the matrix
  /// coprocessor on hardware that has one.
  case cpuMatrix

  public var summary: String {
    switch self {
    case .cpuFloat: return "dense FP64 FMA through NEON"
    case .cpuInteger: return "branch-heavy integer work"
    case .cpuMemory: return "streaming memory access, bandwidth bound"
    case .cpuMatrix: return "FP64 matrix multiply through Accelerate"
    }
  }
}

/// A compute kernel a worker can run.
///
/// The contract every kernel must satisfy:
///
/// 1. `run(iterations:)` performs work proportional to `iterations`.
/// 2. State is bounded for any number of iterations: no overflow, no
///    denormals, and no settling on a constant the hardware could coast
///    through.
/// 3. `checksum` escapes, so nothing can be optimised away.
public protocol ComputeKernel {
  /// Work performed per iteration, for throughput estimates. Zero when the
  /// kernel's unit of work is not a FLOP.
  static var flopsPerIteration: Double { get }

  mutating func run(iterations: Int)
  var checksum: Double { get }
}

// MARK: - Integer

/// Branch-heavy integer work.
///
/// A mix of multiply, shift, xor and a data-dependent branch, so the branch
/// predictor cannot learn the pattern. Deliberately unlike `cpuFloat`: it
/// leaves the FP pipelines idle and loads the integer units and front end
/// instead, which is a measurably different power profile.
///
/// Bounded by construction: everything is unsigned 64-bit arithmetic that wraps
/// rather than overflowing.
public struct CPUIntegerKernel: ComputeKernel, Sendable {

  /// Integer work, not floating point.
  public static let flopsPerIteration: Double = 0

  private var a: UInt64
  private var b: UInt64
  private var c: UInt64
  private var d: UInt64
  private var branchesTaken: UInt64 = 0

  public init(seed: UInt64 = 0) {
    a = 0x243F_6A88_85A3_08D3 &+ seed
    b = 0x1319_8A2E_0370_7344 &+ seed
    c = 0xA409_3822_299F_31D0 &+ seed
    d = 0x082E_FA98_EC4E_6C89 &+ seed
  }

  @inline(never)
  public mutating func run(iterations: Int) {
    guard iterations > 0 else { return }
    var w = a
    var x = b
    var y = c
    var z = d
    var taken = branchesTaken

    for _ in 0..<iterations {
      // xorshift-style mixing: cheap, wraps, and never settles.
      w ^= w << 13
      w ^= w >> 7
      w ^= w << 17
      x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      y = (y &+ w) ^ (x >> 11)

      // Data-dependent and unpredictable, which is the point: a branch the
      // predictor can learn costs nothing and tests nothing.
      if (y & 0xFF) < 0x80 {
        z = z &+ y
        taken &+= 1
      } else {
        z = z ^ (y &* 3)
      }
    }
    a = w
    b = x
    c = y
    d = z
    branchesTaken = taken
  }

  /// Escaping value. Mixing all four words means none of the work is dead.
  public var checksum: Double {
    Double(bitPattern: (a ^ b ^ c ^ d ^ branchesTaken) | 1)
  }

  /// Fraction of branches taken, which should sit near half for an
  /// unpredictable branch. Exposed so a test can prove the branch really is
  /// unpredictable rather than trusting that it is.
  public var takenFraction: Double {
    // Only meaningful relative to iterations, which the caller knows.
    Double(branchesTaken)
  }
}

// MARK: - Memory

/// Streaming memory access, bound by bandwidth.
///
/// Walks a buffer far larger than the last level cache with a stride chosen to
/// defeat the prefetcher, so the bottleneck is the memory controller rather
/// than either execution unit. On Apple silicon this is the kernel that
/// contends with GPU load, since both share the controller.
public struct CPUMemoryKernel: ComputeKernel, @unchecked Sendable {

  /// One add per element touched.
  public static let flopsPerIteration: Double = 1

  /// Comfortably larger than any current Apple silicon last level cache, so
  /// the walk actually reaches memory.
  public static let bufferBytes = 64 * 1024 * 1024

  private let buffer: UnsafeMutablePointer<Double>
  private let elementCount: Int
  /// A large odd stride: coprime with the cache geometry, so successive
  /// accesses land in different sets and the prefetcher cannot lock on.
  private let stride: Int
  private var cursor: Int
  private var accumulator: Double = 0

  public init(seed: UInt64 = 0) {
    elementCount = Self.bufferBytes / MemoryLayout<Double>.stride
    buffer = UnsafeMutablePointer<Double>.allocate(capacity: elementCount)
    buffer.initialize(repeating: 1.000_001, count: elementCount)
    stride = 9973
    cursor = Int(seed % UInt64(elementCount))
  }

  /// Frees the buffer. Not a `deinit` because the struct is copied by value;
  /// the worker that owns it calls this.
  public func release() {
    buffer.deinitialize(count: elementCount)
    buffer.deallocate()
  }

  @inline(never)
  public mutating func run(iterations: Int) {
    guard iterations > 0 else { return }
    var index = cursor
    var total = accumulator
    let count = elementCount

    for _ in 0..<iterations {
      index = index &+ stride
      if index >= count { index -= count }
      // Read and write, so the traffic is bidirectional rather than read-only.
      let value = buffer[index]
      total += value
      buffer[index] = value * 0.999_999 + 0.000_001
    }
    cursor = index
    // Keep the accumulator bounded over an indefinite run.
    accumulator = total.truncatingRemainder(dividingBy: 1_048_576)
  }

  public var checksum: Double { accumulator }
}

// MARK: - Matrix

/// Dense FP64 matrix multiply through Accelerate.
///
/// Accelerate dispatches `dgemm` to whatever the hardware offers, which on
/// Apple silicon includes the matrix coprocessor. That is a different execution
/// resource from the NEON pipelines `cpuFloat` uses, and therefore a different
/// power profile — which matters for a tool whose real output is heat.
///
/// **Whether a given call actually reaches the coprocessor is not something
/// this code can observe.** Accelerate exposes no such flag. What is
/// observable, and is measured, is throughput versus `cpuFloat` on the same
/// core. See `docs/measurements.md`.
public struct CPUMatrixKernel: ComputeKernel, @unchecked Sendable {

  /// Order of the square matrices. Small enough that three of them stay in L2,
  /// large enough that the multiply dominates the call overhead.
  public static let order = 64

  /// `2 n^3` for an n-by-n multiply-accumulate.
  public static var flopsPerIteration: Double {
    2 * pow(Double(order), 3)
  }

  private let a: UnsafeMutablePointer<Double>
  private let b: UnsafeMutablePointer<Double>
  private let c: UnsafeMutablePointer<Double>
  private let elementCount: Int

  public init(seed: UInt64 = 0) {
    let n = Self.order
    elementCount = n * n
    a = .allocate(capacity: elementCount)
    b = .allocate(capacity: elementCount)
    c = .allocate(capacity: elementCount)

    // Values near 1 with a small spread: the product stays well conditioned
    // over an indefinite run instead of growing without bound.
    for index in 0..<elementCount {
      let offset = Double((index &+ Int(seed % 97)) % 17) * 0.001
      a[index] = 1.0 + offset
      b[index] = 1.0 - offset
      c[index] = 0
    }
  }

  public func release() {
    a.deallocate()
    b.deallocate()
    c.deallocate()
  }

  @inline(never)
  public mutating func run(iterations: Int) {
    guard iterations > 0 else { return }
    let n = Int32(Self.order)
    for _ in 0..<iterations {
      // beta = 0 so C is overwritten rather than accumulating without bound.
      cblas_dgemm(
        CblasRowMajor, CblasNoTrans, CblasNoTrans,
        n, n, n,
        1.0, a, n, b, n,
        0.0, c, n)
    }
  }

  public var checksum: Double { c[0] + c[elementCount - 1] }
}

// MARK: - Dispatch

/// A compute kernel chosen at run time.
///
/// An enum rather than an existential so the hot loop has no witness-table
/// call. The switch happens once per chunk, roughly every 200 microseconds,
/// not once per iteration.
public enum AnyComputeKernel: @unchecked Sendable {
  case float(CPUFloatKernel)
  case integer(CPUIntegerKernel)
  case memory(CPUMemoryKernel)
  case matrix(CPUMatrixKernel)

  public init(kind: WorkerKind, seed: UInt64) {
    switch kind {
    case .cpuFloat: self = .float(CPUFloatKernel(seed: seed))
    case .cpuInteger: self = .integer(CPUIntegerKernel(seed: seed))
    case .cpuMemory: self = .memory(CPUMemoryKernel(seed: seed))
    case .cpuMatrix: self = .matrix(CPUMatrixKernel(seed: seed))
    }
  }

  public var kind: WorkerKind {
    switch self {
    case .float: return .cpuFloat
    case .integer: return .cpuInteger
    case .memory: return .cpuMemory
    case .matrix: return .cpuMatrix
    }
  }

  /// Work per iteration, for throughput estimates.
  public var flopsPerIteration: Double {
    switch self {
    case .float: return Double(CPUFloatKernel.flopsPerIteration)
    case .integer: return CPUIntegerKernel.flopsPerIteration
    case .memory: return CPUMemoryKernel.flopsPerIteration
    case .matrix: return CPUMatrixKernel.flopsPerIteration
    }
  }

  public mutating func run(iterations: Int) {
    switch self {
    case .float(var kernel):
      kernel.run(iterations: iterations)
      self = .float(kernel)
    case .integer(var kernel):
      kernel.run(iterations: iterations)
      self = .integer(kernel)
    case .memory(var kernel):
      kernel.run(iterations: iterations)
      self = .memory(kernel)
    case .matrix(var kernel):
      kernel.run(iterations: iterations)
      self = .matrix(kernel)
    }
  }

  public var checksum: Double {
    switch self {
    case .float(let kernel): return kernel.checksum
    case .integer(let kernel): return kernel.checksum
    case .memory(let kernel): return kernel.checksum
    case .matrix(let kernel): return kernel.checksum
    }
  }

  /// Frees any heap buffers. Kernels that allocate cannot use `deinit`,
  /// because the enum is copied by value.
  public func release() {
    switch self {
    case .memory(let kernel): kernel.release()
    case .matrix(let kernel): kernel.release()
    case .float, .integer: break
    }
  }

  /// A first-chunk iteration count that lands near the chunk target for this
  /// kernel. A dgemm iteration is roughly a million times more work than an
  /// integer iteration, so one seed cannot serve both.
  public var calibrationIterations: Int {
    switch self {
    case .float, .integer: return 2_048
    case .memory: return 4_096
    case .matrix: return 4
    }
  }
}
