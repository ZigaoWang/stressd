import Foundation
import Metal

/// Which bottleneck a GPU profile targets.
public enum GPUProfile: String, Sendable, Codable, CaseIterable {
  /// Register-resident fused multiply-add. Almost no memory traffic.
  case alu
  /// Streaming reads. Bound by memory bandwidth.
  case bandwidth
  /// Arithmetic with periodic memory access, which is what most real work
  /// looks like.
  case mixed

  var functionName: String {
    switch self {
    case .alu: return "stressd_alu"
    case .bandwidth: return "stressd_bandwidth"
    case .mixed: return "stressd_mixed"
    }
  }

  /// Floating point operations per thread per iteration.
  ///
  /// Counted from the kernel source: `alu` does four `fma`, each a multiply
  /// and an add.
  var flopsPerIteration: Double {
    switch self {
    case .alu: return 8
    case .mixed: return 4
    case .bandwidth: return 1
    }
  }
}

/// One threadgroup geometry, and how fast it turned out to be.
public struct GPUGeometry: Sendable, Codable, Equatable {
  public let threadsPerThreadgroup: Int
  public let threadgroupCount: Int
  /// Seconds for one benchmark dispatch. Lower is better.
  public let dispatchSeconds: Double

  public var totalThreads: Int { threadsPerThreadgroup * threadgroupCount }
}

/// A read of the GPU worker's counters.
public struct GPUWorkerSample: Sendable, Codable, Equatable {
  public let profile: GPUProfile
  public let requestedDutyCycle: Double
  public let achievedDutyCycle: Double?
  public let dispatches: UInt64
  /// Estimated throughput. **An estimate from a counted FLOP-per-iteration
  /// figure, not a benchmark score.**
  public let estimatedGigaflops: Double?
  public let geometry: GPUGeometry?
  public let deviceName: String
}

/// Duty-cycled Metal compute load.
///
/// ## Duty cycling a GPU
///
/// There is no preemption knob, so the duty cycle is the ratio of dispatch time
/// to wall time: submit a batch of work, wait for it, then sleep long enough
/// that the busy fraction matches the target. The same anchored-deadline and
/// work-debt accounting as the CPU worker, for the same reasons.
///
/// The batch is sized from a measured dispatch rate so one batch lands near the
/// target chunk length. A dispatch cannot be interrupted once submitted, so
/// batch length sets the granularity of control.
public final class MetalGPUWorker: @unchecked Sendable {

  /// Target length of one dispatch batch.
  ///
  /// This sets the granularity of duty cycle control: a dispatch cannot be cut
  /// short once submitted, so the last batch of a cycle can overrun the work
  /// deadline by up to one batch. At 10 ms against a 200 ms period that is a
  /// 5% worst-case error, which is why the GPU duty tolerance is wider than
  /// the CPU's.
  private static let batchTargetNanoseconds: UInt64 = 10_000_000

  /// Duty cycle period. Longer than the CPU worker's because a GPU dispatch
  /// cannot be cut short once submitted.
  public static let defaultPeriodNanoseconds: UInt64 = 200_000_000

  private static let benchmarkIterations: UInt32 = 2_000
  private static let bufferElementCount = 4 * 1024 * 1024

  public let profile: GPUProfile
  public let deviceName: String

  private let device: any MTLDevice
  private let queue: any MTLCommandQueue
  private let pipeline: any MTLComputePipelineState
  private let outputBuffer: any MTLBuffer
  private let inputBuffer: any MTLBuffer
  private let clock: any MonotonicClock

  private let dutyCycle = AtomicDouble(0)
  private let isRunningFlag = AtomicFlag(false)
  private let gate: WorkerGate
  private let dispatches = AtomicUInt64()
  private let busyNanoseconds = AtomicUInt64()
  private let elapsedNanoseconds = AtomicUInt64()
  private let iterationsRun = AtomicUInt64()

  private var thread: Thread?
  private let lifecycleLock = NSLock()
  private var chosenGeometry: GPUGeometry?

  /// Builds a worker, or returns `nil` on a machine with no usable Metal
  /// device. GPU load is always optional.
  public init?(
    profile: GPUProfile = .mixed,
    device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
    clock: any MonotonicClock = MachMonotonicClock()
  ) {
    guard let device else { return nil }
    guard let queue = device.makeCommandQueue() else { return nil }
    guard let library = Self.makeLibrary(device: device) else { return nil }

    guard let function = library.makeFunction(name: profile.functionName) else { return nil }
    guard let pipeline = try? device.makeComputePipelineState(function: function) else {
      return nil
    }

    let bytes = Self.bufferElementCount * MemoryLayout<Float>.stride
    guard let output = device.makeBuffer(length: bytes, options: .storageModeShared),
      let input = device.makeBuffer(length: bytes, options: .storageModeShared)
    else { return nil }

    // Seed the input so bandwidth reads are not all zero pages.
    let pointer = input.contents().bindMemory(
      to: Float.self, capacity: Self.bufferElementCount)
    for index in 0..<Self.bufferElementCount {
      pointer[index] = Float(index % 1024) * 0.001
    }

    self.profile = profile
    self.device = device
    self.deviceName = device.name
    self.queue = queue
    self.pipeline = pipeline
    self.outputBuffer = output
    self.inputBuffer = input
    self.clock = clock
    self.gate = WorkerGate(dutyCycle: dutyCycle, isRunning: isRunningFlag)
  }

  /// Compiles the embedded shader source.
  ///
  /// See `GPUShaderSource` for why the source is embedded rather than shipped
  /// as a metallib. Cached, because compilation is not free and every worker
  /// needs the same library.
  private static let libraryCache = LibraryCache()

  private final class LibraryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var library: (any MTLLibrary)?

    func library(for device: any MTLDevice) -> (any MTLLibrary)? {
      lock.lock()
      defer { lock.unlock() }
      if let library { return library }
      let compiled = try? device.makeLibrary(source: GPUShaderSource.metal, options: nil)
      library = compiled
      return compiled
    }
  }

  private static func makeLibrary(device: any MTLDevice) -> (any MTLLibrary)? {
    libraryCache.library(for: device)
  }

  // MARK: - Geometry selection

  /// Benchmarks a few threadgroup geometries and keeps the fastest.
  ///
  /// The best shape is not predictable from the device alone: it depends on the
  /// kernel's register pressure and on how many threadgroups it takes to fill
  /// the machine. Measuring takes well under a second and removes the guess.
  @discardableResult
  public func selectGeometry() -> GPUGeometry? {
    let maximumThreads = pipeline.maxTotalThreadsPerThreadgroup
    let width = pipeline.threadExecutionWidth

    let candidateThreadCounts = [width, width * 2, width * 4, maximumThreads]
      .filter { $0 > 0 && $0 <= maximumThreads }
    let uniqueCounts = Array(Set(candidateThreadCounts)).sorted()

    var best: GPUGeometry?
    for threadsPerGroup in uniqueCounts {
      // Enough groups to cover the output buffer without exceeding it.
      let groups = max(1, min(4096, Self.bufferElementCount / max(threadsPerGroup, 1)))
      let elapsed = benchmark(threadsPerGroup: threadsPerGroup, groups: groups)
      guard elapsed > 0 else { continue }
      let geometry = GPUGeometry(
        threadsPerThreadgroup: threadsPerGroup, threadgroupCount: groups,
        dispatchSeconds: elapsed)
      if best == nil || elapsed < (best?.dispatchSeconds ?? .infinity) {
        best = geometry
      }
    }
    chosenGeometry = best
    return best
  }

  private func benchmark(threadsPerGroup: Int, groups: Int) -> Double {
    // One warm-up dispatch so shader compilation and buffer residency are not
    // counted as run time.
    _ = dispatch(
      iterations: Self.benchmarkIterations, threadsPerGroup: threadsPerGroup, groups: groups)
    return dispatch(
      iterations: Self.benchmarkIterations, threadsPerGroup: threadsPerGroup, groups: groups)
  }

  /// Submits one batch and waits for it. Returns seconds elapsed.
  @discardableResult
  private func dispatch(iterations: UInt32, threadsPerGroup: Int, groups: Int) -> Double {
    guard let buffer = queue.makeCommandBuffer(),
      let encoder = buffer.makeComputeCommandEncoder()
    else { return 0 }

    var iterationCount = iterations
    var elementCount = UInt32(Self.bufferElementCount)

    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(outputBuffer, offset: 0, index: 0)
    encoder.setBytes(&iterationCount, length: MemoryLayout<UInt32>.size, index: 1)
    encoder.setBuffer(inputBuffer, offset: 0, index: 2)
    encoder.setBytes(&elementCount, length: MemoryLayout<UInt32>.size, index: 3)
    encoder.dispatchThreadgroups(
      MTLSize(width: groups, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
    encoder.endEncoding()

    let start = clock.nanoseconds()
    buffer.commit()
    buffer.waitUntilCompleted()
    let elapsed = clock.nanoseconds() &- start

    dispatches.add(1)
    iterationsRun.add(UInt64(iterations) * UInt64(groups * threadsPerGroup))
    return Double(elapsed) / 1e9
  }

  // MARK: - Lifecycle

  public var isRunning: Bool { isRunningFlag.value }
  public var geometry: GPUGeometry? { chosenGeometry }

  public func start(dutyCycle target: Double) {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard thread == nil else {
      gate.setDutyCycle(Self.clamp(target))
      return
    }
    if chosenGeometry == nil { selectGeometry() }

    isRunningFlag.value = true
    gate.setDutyCycle(Self.clamp(target))

    let worker = Thread { [weak self] in self?.run() }
    worker.name = "stressd.gpu"
    worker.qualityOfService = .userInitiated
    worker.stackSize = 256 * 1024
    worker.start()
    thread = worker
  }

  /// Changes the duty cycle on the live dispatch loop. Never respawns.
  public func setDutyCycle(_ target: Double) {
    gate.setDutyCycle(Self.clamp(target))
  }

  public func stop() {
    lifecycleLock.lock()
    let running = thread
    thread = nil
    lifecycleLock.unlock()

    guard let running else {
      isRunningFlag.value = false
      return
    }
    gate.stop()
    // A dispatch in flight cannot be cancelled, so the bound allows for one
    // batch to finish.
    let deadline = Date().addingTimeInterval(5)
    while !running.isFinished, Date() < deadline {
      usleep(2_000)
    }
  }

  public func snapshot() -> GPUWorkerSample {
    let busy = busyNanoseconds.load()
    let elapsed = elapsedNanoseconds.load()
    let achieved = elapsed > 0 ? Double(busy) / Double(elapsed) : nil

    var gigaflops: Double?
    if busy > 0 {
      gigaflops = Double(iterationsRun.load()) * profile.flopsPerIteration / Double(busy)
    }

    return GPUWorkerSample(
      profile: profile,
      requestedDutyCycle: dutyCycle.load(),
      achievedDutyCycle: achieved,
      dispatches: dispatches.load(),
      estimatedGigaflops: gigaflops,
      geometry: chosenGeometry,
      deviceName: deviceName)
  }

  // MARK: - Loop

  private func run() {
    guard let geometry = chosenGeometry ?? selectGeometry() else { return }

    var scheduler = DutyCycleScheduler(
      anchor: clock.nanoseconds(), periodNanoseconds: Self.defaultPeriodNanoseconds)
    var iterationsPerBatch = Self.benchmarkIterations
    // Seed the batch size from the benchmark so the first cycle is not wild.
    if geometry.dispatchSeconds > 0 {
      let scale = Double(Self.batchTargetNanoseconds) / (geometry.dispatchSeconds * 1e9)
      iterationsPerBatch = UInt32(
        min(max(Double(Self.benchmarkIterations) * scale, 1), 4_000_000))
    }

    var cycleStart = clock.nanoseconds()

    while isRunningFlag.value {
      var target = dutyCycle.load()
      if target <= 0 {
        guard gate.parkUntilWorkAvailable() else { break }
        cycleStart = clock.nanoseconds()
        scheduler.reanchor(to: cycleStart)
        target = dutyCycle.load()
        if target <= 0 { continue }
      }

      let cycle = scheduler.nextCycle(now: cycleStart, dutyCycle: target)
      var busy: UInt64 = 0

      // Dispatch batches until the work deadline. The last batch can overrun,
      // since a dispatch cannot be cut short; the debt accounting repays it.
      while clock.nanoseconds() < cycle.workDeadline, isRunningFlag.value {
        let before = clock.nanoseconds()
        let seconds = dispatch(
          iterations: iterationsPerBatch,
          threadsPerGroup: geometry.threadsPerThreadgroup,
          groups: geometry.threadgroupCount)
        let after = clock.nanoseconds()
        busy &+= after &- before

        // Re-size the batch towards the target length as the clock changes.
        if seconds > 0 {
          let scale = Double(Self.batchTargetNanoseconds) / (seconds * 1e9)
          let adjusted = Double(iterationsPerBatch) * min(max(scale, 0.5), 2.0)
          iterationsPerBatch = UInt32(min(max(adjusted, 1), 4_000_000))
        }
      }

      scheduler.completeCycle(workedNanoseconds: busy)
      if !cycle.isSaturated {
        clock.wait(untilNanoseconds: cycle.end)
      }

      let next = clock.nanoseconds()
      busyNanoseconds.add(busy)
      elapsedNanoseconds.add(next &- cycleStart)
      cycleStart = next
    }
  }

  private static func clamp(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }
}
