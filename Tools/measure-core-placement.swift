#!/usr/bin/env swift
//
// Where does the scheduler put threads of a given QoS class, and does that
// change over time?
//
//     swift Tools/measure-core-placement.swift [--threads N] [--seconds S]
//                                              [--stagger S] [--qos CLASS]
//
// Emits a per-second time series, not an average. That distinction is the
// whole point: an averaged measurement cannot tell a scheduler that never uses
// the performance cores apart from one that engages them after a delay. If
// P-core utilization climbs and plateaus, then every short placement
// measurement is biased low and needs a stated settling window.
//
// On Apple silicon logical CPUs are numbered efficiency cores first, so a
// low-numbered block lighting up means work landed on E-cores. Confirm the
// numbering for your machine with `stressd topology`.
//
// Output is tab separated, with comment lines prefixed `#`, so it pastes
// straight into a spreadsheet.

import Darwin
import Foundation

// MARK: - Arguments

var threadCount = ProcessInfo.processInfo.activeProcessorCount / 2
var durationSeconds = 120
var staggerSeconds = 0
var qosName = "userInteractive"

var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
  arguments.removeFirst()
  guard let value = arguments.first else { break }
  arguments.removeFirst()
  switch flag {
  case "--threads": threadCount = Int(value) ?? threadCount
  case "--seconds": durationSeconds = Int(value) ?? durationSeconds
  case "--stagger": staggerSeconds = Int(value) ?? staggerSeconds
  case "--qos": qosName = value
  default: break
  }
}

let qosClasses: [String: qos_class_t] = [
  "userInteractive": QOS_CLASS_USER_INTERACTIVE,
  "userInitiated": QOS_CLASS_USER_INITIATED,
  "default": QOS_CLASS_DEFAULT,
  "utility": QOS_CLASS_UTILITY,
  "background": QOS_CLASS_BACKGROUND,
]
let qos = qosClasses[qosName] ?? QOS_CLASS_USER_INTERACTIVE

// MARK: - Sampling

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

/// Busy fraction per logical CPU between two tick reads.
func busy(from before: [[UInt32]], to after: [[UInt32]]) -> [Double] {
  (0..<min(before.count, after.count)).map { cpu in
    let delta = (0..<4).map { Double(after[cpu][$0] &- before[cpu][$0]) }
    let total = delta.reduce(0, +)
    // Index 2 is CPU_STATE_IDLE.
    return total > 0 ? (total - delta[2]) / total : 0
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

// MARK: - Run

let cores = ProcessInfo.processInfo.activeProcessorCount
let half = cores / 2

print("# logical CPUs: \(cores), assuming cpu0-\(half - 1) are efficiency cores")
print("# PRIO_DARWIN_PROCESS = \(getpriority(PRIO_DARWIN_PROCESS, 0))  (1 means throttled)")
print(
  "# qos=\(qosName) threads=\(threadCount) seconds=\(durationSeconds) "
    + "stagger=\(staggerSeconds)")

// Baseline before any load, so the series can be read as a delta.
var previous = readTicks()
Thread.sleep(forTimeInterval: 3)
var current = readTicks()
let baseline = busy(from: previous, to: current)
let baselineE = baseline.prefix(half).reduce(0, +) / Double(half)
let baselineP = baseline.dropFirst(half).reduce(0, +) / Double(cores - half)
print(String(format: "# baseline  E=%.1f%%  P=%.1f%%", baselineE * 100, baselineP * 100))

let stop = StopFlag()
var workers: [Thread] = []

func spawnWorker() {
  let thread = Thread {
    pthread_set_qos_class_self_np(qos, 0)
    var x = 1.0
    while !stop.isStopped() {
      for _ in 0..<100_000 { x = x * 0.999_999 + 0.000_001 }
      if x < -1e9 { print(x) }
    }
  }
  thread.qualityOfService =
    qos == QOS_CLASS_BACKGROUND
    ? .background : (qos == QOS_CLASS_UTILITY ? .utility : .userInteractive)
  thread.start()
  workers.append(thread)
}

// Either all at once, or spread over the stagger window. A simultaneous burst
// of runnable threads may look different to the scheduler than a gradual ramp.
if staggerSeconds <= 0 {
  for _ in 0..<threadCount { spawnWorker() }
} else {
  print("# staggering \(threadCount) threads over \(staggerSeconds)s")
}

let staggerInterval = staggerSeconds > 0 ? Double(staggerSeconds) / Double(threadCount) : 0
var nextSpawnAt = 0.0

// One column per logical CPU, then the two cluster means.
var header = ["t"]
header += (0..<cores).map { "cpu\($0)" }
header += ["E_mean", "P_mean", "threads"]
print(header.joined(separator: "\t"))

previous = readTicks()
for second in 0..<durationSeconds {
  if staggerSeconds > 0 {
    while workers.count < threadCount, nextSpawnAt <= Double(second) {
      spawnWorker()
      nextSpawnAt += staggerInterval
    }
  }

  Thread.sleep(forTimeInterval: 1)
  current = readTicks()
  let sample = busy(from: previous, to: current)
  previous = current

  let eMean = sample.prefix(half).reduce(0, +) / Double(half)
  let pMean = sample.dropFirst(half).reduce(0, +) / Double(cores - half)

  var row = [String(second + 1)]
  row += sample.map { String(format: "%.1f", $0 * 100) }
  row += [
    String(format: "%.1f", eMean * 100),
    String(format: "%.1f", pMean * 100),
    String(workers.count),
  ]
  print(row.joined(separator: "\t"))
  fflush(stdout)
}

stop.stop()
for worker in workers { while !worker.isFinished { usleep(2_000) } }
print("# done")
