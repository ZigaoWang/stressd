import Foundation
import Metal
import Testing

@testable import StressKit

/// Whether this host has a usable Metal device. CI runners often do not.
enum GPUHost {
  static var isAvailable: Bool {
    MTLCreateSystemDefaultDevice() != nil
  }
}

@Suite("GPU worker")
struct GPUWorkerTests {

  @Test("Every profile maps to a kernel that exists in the embedded source")
  func profilesMapToKernels() {
    // Cheap guard against a profile being added without its shader, which
    // would otherwise fail only at runtime on a machine with a GPU.
    for profile in GPUProfile.allCases {
      #expect(
        GPUShaderSource.metal.contains("kernel void \(profile.functionName)"),
        "no kernel named \(profile.functionName)")
      #expect(profile.flopsPerIteration > 0)
    }
  }

  @Test("The embedded shader stores its result so the loop cannot be elided")
  func kernelsWriteOutput() {
    // The GPU equivalent of the CPU kernel's escaping store. Without a write
    // to a host-visible buffer the compiler is free to delete the whole loop.
    let source = GPUShaderSource.metal
    for profile in GPUProfile.allCases {
      guard let range = source.range(of: "kernel void \(profile.functionName)") else {
        Issue.record("missing kernel \(profile.functionName)")
        continue
      }
      let body = source[range.lowerBound...].prefix(1400)
      #expect(body.contains("output[gid]"), "\(profile.functionName) never writes output")
    }
  }

  @Test("Geometry comparison prefers the faster dispatch")
  func geometryPrefersFaster() {
    let slow = GPUGeometry(
      threadsPerThreadgroup: 32, threadgroupCount: 128, dispatchSeconds: 0.02)
    let fast = GPUGeometry(
      threadsPerThreadgroup: 256, threadgroupCount: 64, dispatchSeconds: 0.004)
    #expect(fast.dispatchSeconds < slow.dispatchSeconds)
    #expect(fast.totalThreads == 16384)
  }

  @Test(
    "A real device benchmarks geometries and picks one",
    .enabled(if: GPUHost.isAvailable), .timeLimit(.minutes(1)))
  func selectsGeometryOnHardware() throws {
    let worker = try #require(MetalGPUWorker(profile: .alu))
    let geometry = try #require(worker.selectGeometry())

    #expect(geometry.threadsPerThreadgroup > 0)
    #expect(geometry.threadgroupCount > 0)
    #expect(geometry.dispatchSeconds > 0)
  }

  @Test(
    "A duty cycle below 100% leaves the GPU idle part of the time",
    .enabled(if: GPUHost.isAvailable), .timeLimit(.minutes(2)))
  func dutyCycleOnHardware() async throws {
    let worker = try #require(MetalGPUWorker(profile: .alu))
    defer { worker.stop() }

    worker.start(dutyCycle: 0.5)
    try await Task.sleep(for: .seconds(6))
    let sample = worker.snapshot()
    worker.stop()

    let achieved = try #require(sample.achievedDutyCycle)
    // Looser than the CPU worker's tolerance on purpose: a dispatch cannot be
    // cut short once submitted, so batch length is the granularity of control.
    #expect(
      abs(achieved - 0.5) < 0.15,
      "GPU achieved \(achieved) for a 50% request")
    #expect(sample.dispatches > 0)
  }

  @Test(
    "Parking at zero stops dispatching without tearing the worker down",
    .enabled(if: GPUHost.isAvailable), .timeLimit(.minutes(2)))
  func parksAtZero() async throws {
    let worker = try #require(MetalGPUWorker(profile: .alu))
    defer { worker.stop() }

    worker.start(dutyCycle: 0.4)
    try await Task.sleep(for: .seconds(3))
    worker.setDutyCycle(0)
    try await Task.sleep(for: .seconds(1))

    let before = worker.snapshot().dispatches
    try await Task.sleep(for: .seconds(3))
    let after = worker.snapshot().dispatches
    #expect(after == before, "a parked GPU worker must not dispatch")

    // And it wakes without a respawn.
    worker.setDutyCycle(0.4)
    try await Task.sleep(for: .seconds(3))
    #expect(worker.snapshot().dispatches > after)
    worker.stop()
  }

  @Test("A machine with no Metal device yields no worker rather than crashing")
  func noDeviceIsNil() {
    // GPU load is always optional.
    #expect(MetalGPUWorker(profile: .alu, device: nil) == nil)
  }
}
