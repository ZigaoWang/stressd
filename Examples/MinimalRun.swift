#!/usr/bin/env swift
//
// The smallest useful StressKit program: start load, read telemetry, stop.
//
//     swift run --package-path . 2>/dev/null   # or paste into your own target
//
// If this is awkward to write, the API is wrong. It is kept short on purpose.

import Foundation
import StressKit

// 1. Read the machine. Nothing is assumed about core counts or chip.
let topology = try CoreTopologyDetector().detect()
print("\(topology.chipName ?? topology.machineModel): \(topology.logicalCoreCount) cores")

// 2. Measure what the machine is already doing. On a real desktop this is
//    rarely zero, and every figure below is reported against it.
let baselineSampler = try CPUUtilizationSampler(topology: topology)
try await Task.sleep(for: .seconds(3))
let baseline = try await baselineSampler.sample()?.systemWide ?? 0
print(String(format: "baseline: %.1f%%", baseline * 100))

// 3. Start synthetic load at 50% of the machine.
let source = SyntheticSource(topology: topology)
try await source.start(budget: ResourceBudget(cpu: 0.5))

// 4. Read telemetry for ten seconds.
let monitor = TelemetryMonitor(topology: topology, interval: 1)
await monitor.observe([source])

var samples = 0
for await telemetry in await monitor.stream() {
  let delta = max(0, telemetry.cpu.systemWide - baseline)
  print(
    String(
      format: "  total %.1f%%  delta %.1f%%  thermal %@",
      telemetry.cpu.systemWide * 100, delta * 100, telemetry.thermalState.rawValue))
  samples += 1
  if samples >= 10 { break }
}

// 5. Stop. Workers are torn down and nothing is left running.
await source.stop()
print("stopped")
