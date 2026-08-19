#!/usr/bin/env swift
//
// Measures the two things that decide how the synthetic worker sets its thread
// policy: how far mach_wait_until overshoots at each QoS class and latency
// tier, and where the resulting threads actually run.
//
// The tables in ThreadTimerPolicy come from this script. Re-run it on new
// hardware or a new macOS release before trusting them:
//
//     swift Tools/measure-timer-coalescing.swift
//
// Takes about a minute and puts the machine under load while it runs.

import Darwin
import Foundation

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

func nanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func machTicks(_ value: UInt64) -> UInt64 {
  let numer = UInt64(timebase.numer)
  let denom = UInt64(timebase.denom)
  return (value / numer) * denom + ((value % numer) * denom) / numer
}

func setLatencyTier(_ tier: Int32) {
  var policy = thread_latency_qos_policy_data_t(thread_latency_qos_tier: tier)
  let count = mach_msg_type_number_t(
    MemoryLayout<thread_latency_qos_policy_data_t>.size / MemoryLayout<integer_t>.size)
  _ = withUnsafeMutablePointer(to: &policy) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      thread_policy_set(
        mach_thread_self(), thread_policy_flavor_t(THREAD_LATENCY_QOS_POLICY), $0, count)
    }
  }
}

func readTicks() -> [[UInt32]] {
  var cpuCount: natural_t = 0
  var info: processor_info_array_t?
  var infoCount: mach_msg_type_number_t = 0
  host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
  guard let info else { return [] }
  defer {
    vm_deallocate(
      mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * 4))
  }
  return (0..<Int(cpuCount)).map { cpu in
    (0..<4).map { UInt32(bitPattern: info[cpu * 4 + $0]) }
  }
}

final class StopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  func isStopped() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
}

/// Median overshoot on a requested 2.5 ms sleep.
func measureOvershoot(qos: qos_class_t, tier: Int32?) -> Int64 {
  var median: Int64 = 0
  let thread = Thread {
    pthread_set_qos_class_self_np(qos, 0)
    if let tier { setLatencyTier(tier) }
    var samples: [Int64] = []
    for _ in 0..<120 {
      let deadline = nanoseconds() + 2_500_000
      mach_wait_until(machTicks(deadline))
      samples.append(Int64(nanoseconds()) - Int64(deadline))
    }
    samples.sort()
    median = samples[samples.count / 2]
  }
  thread.start()
  while !thread.isFinished { usleep(3_000) }
  return median
}

/// Mean busy fraction per core class while six duty-cycled threads run.
func measurePlacement(qos: qos_class_t, tier: Int32?, cores: Int) -> (
  efficiency: Int, performance: Int
) {
  let stop = StopFlag()
  var threads: [Thread] = []
  for _ in 0..<6 {
    let thread = Thread {
      pthread_set_qos_class_self_np(qos, 0)
      if let tier { setLatencyTier(tier) }
      var accumulator = 1.0
      while !stop.isStopped() {
        let deadline = nanoseconds() + 2_500_000
        while nanoseconds() < deadline {
          for _ in 0..<2_000 { accumulator = accumulator * 0.999_999 + 0.000_001 }
        }
        mach_wait_until(machTicks(nanoseconds() + 2_500_000))
        if accumulator < -1e9 { print(accumulator) }
      }
    }
    thread.start()
    threads.append(thread)
  }

  Thread.sleep(forTimeInterval: 1.5)
  let before = readTicks()
  Thread.sleep(forTimeInterval: 2.5)
  let after = readTicks()
  stop.stop()
  for thread in threads { while !thread.isFinished { usleep(2_000) } }

  let busy = (0..<before.count).map { cpu -> Int in
    let delta = (0..<4).map { Double(after[cpu][$0] &- before[cpu][$0]) }
    let total = delta.reduce(0, +)
    return total > 0 ? Int((total - delta[2]) / total * 100) : 0
  }
  let half = cores / 2
  return (
    busy[0..<half].reduce(0, +) / half,
    busy[half..<cores].reduce(0, +) / (cores - half)
  )
}

let cores = ProcessInfo.processInfo.activeProcessorCount
print("cores: \(cores)   (assumes efficiency cores are numbered first)\n")

let classes: [(String, qos_class_t)] = [
  ("userInteractive", QOS_CLASS_USER_INTERACTIVE),
  ("utility", QOS_CLASS_UTILITY),
  ("background", QOS_CLASS_BACKGROUND),
]
let tiers: [(String, Int32?)] = [
  ("default", nil),
  ("tier0", Int32(bitPattern: LATENCY_QOS_TIER_0.rawValue)),
  ("tier1", Int32(bitPattern: LATENCY_QOS_TIER_1.rawValue)),
  ("tier2", Int32(bitPattern: LATENCY_QOS_TIER_2.rawValue)),
  ("tier3", Int32(bitPattern: LATENCY_QOS_TIER_3.rawValue)),
]

print("Sleep overshoot, median over 120 requested 2.5 ms sleeps")
print("qos               tier        overshoot")
for (className, qos) in classes {
  for (tierName, tier) in tiers {
    let overshoot = measureOvershoot(qos: qos, tier: tier)
    print(
      "\(className.padding(toLength: 18, withPad: " ", startingAt: 0))"
        + "\(tierName.padding(toLength: 12, withPad: " ", startingAt: 0))"
        + String(format: "%7d us", overshoot / 1000))
  }
}

print("\nCore placement of six .background threads at 50% duty")
print("tier        E-cores   P-cores")
for (tierName, tier) in tiers {
  let placement = measurePlacement(qos: QOS_CLASS_BACKGROUND, tier: tier, cores: cores)
  print(
    "\(tierName.padding(toLength: 12, withPad: " ", startingAt: 0))"
      + String(format: "%6d%%%9d%%", placement.efficiency, placement.performance))
}
