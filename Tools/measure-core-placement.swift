#!/usr/bin/env swift
//
// Where does the scheduler put threads of a given QoS class, and does that
// change over time?
//
//     swift Tools/measure-core-placement.swift [--threads N] [--seconds S]
//                                              [--stagger S] [--qos CLASS]
//                                              [--json]
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
// Every run begins with a diagnostic block describing the scheduling context
// it ran in. That exists because this project has already produced one
// placement reading nobody can reproduce or explain. Rather than keep chasing
// it, each measurement now carries its own provenance, so the next anomaly is
// diagnosable from its own output. See docs/mechanisms.md section 3.
//
// Text output is tab separated with `#` comments, so it pastes into a
// spreadsheet. `--json` emits one object with the same diagnostics plus the
// full series.

import Darwin
import Foundation

// MARK: - Arguments

var threadCount = ProcessInfo.processInfo.activeProcessorCount / 2
var durationSeconds = 120
var staggerSeconds = 0
var qosName = "userInteractive"
var emitJSON = false

var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
  arguments.removeFirst()
  if flag == "--json" {
    emitJSON = true
    continue
  }
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

// MARK: - Scheduling context diagnostics

/// Names for `qos_class_t`, which is an opaque integer in Swift.
func qosName(_ value: qos_class_t) -> String {
  switch value.rawValue {
  case 0x21: return "USER_INTERACTIVE"
  case 0x19: return "USER_INITIATED"
  case 0x15: return "DEFAULT"
  case 0x11: return "UTILITY"
  case 0x09: return "BACKGROUND"
  case 0x00: return "UNSPECIFIED"
  default: return "raw(\(value.rawValue))"
  }
}

/// The task's scheduling role.
///
/// This is the check that matters most here. A thread's QoS reading back as
/// `USER_INTERACTIVE` does **not** mean the task is eligible for performance
/// cores: `TASK_BACKGROUND_APPLICATION` and `TASK_NONUI_APPLICATION` clamp
/// effective scheduling at the task level regardless of what any thread asked
/// for. It is the one candidate for the unreproduced outlier that was never
/// checked directly.
func taskRole() -> (value: Int32, name: String) {
  var policy = task_category_policy_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_category_policy_data_t>.size / MemoryLayout<integer_t>.size)
  var isDefault: boolean_t = 0

  let status = withUnsafeMutablePointer(to: &policy) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
      task_policy_get(
        mach_task_self_, task_policy_flavor_t(TASK_CATEGORY_POLICY), rebound, &count,
        &isDefault)
    }
  }
  guard status == KERN_SUCCESS else { return (-99, "unavailable (kr \(status))") }

  let names: [Int32: String] = [
    -1: "TASK_RENICED",
    0: "TASK_UNSPECIFIED",
    1: "TASK_FOREGROUND_APPLICATION",
    2: "TASK_BACKGROUND_APPLICATION",
    3: "TASK_CONTROL_APPLICATION",
    4: "TASK_GRAPHICS_SERVER",
    5: "TASK_THROTTLE_APPLICATION",
    6: "TASK_NONUI_APPLICATION",
    7: "TASK_DEFAULT_APPLICATION",
  ]
  let role = Int32(policy.role.rawValue)
  return (role, names[role] ?? "unknown(\(role))")
}

/// The calling thread's timer latency tier, in case something set one.
func threadLatencyTier() -> String {
  var policy = thread_latency_qos_policy_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<thread_latency_qos_policy_data_t>.size / MemoryLayout<integer_t>.size)
  var isDefault: boolean_t = 0

  let status = withUnsafeMutablePointer(to: &policy) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
      thread_policy_get(
        mach_thread_self(), thread_policy_flavor_t(THREAD_LATENCY_QOS_POLICY), rebound,
        &count, &isDefault)
    }
  }
  guard status == KERN_SUCCESS else { return "unavailable" }
  let tier = policy.thread_latency_qos_tier
  return tier == 0 ? "UNSPECIFIED (0)" : "tier \(tier)"
}

/// The parent process name, via `sysctl`. A shell, a CI runner and a GUI app
/// are different scheduling contexts and it is worth recording which one.
func parentProcessName() -> String {
  let parent = getppid()
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, parent]
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
    return "pid \(parent)"
  }
  let name = withUnsafePointer(to: info.kp_proc.p_comm) { pointer in
    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
      String(cString: $0)
    }
  }
  return name.isEmpty ? "pid \(parent)" : "\(name) (pid \(parent))"
}

func thermalName(_ state: ProcessInfo.ThermalState) -> String {
  switch state {
  case .nominal: return "nominal"
  case .fair: return "fair"
  case .serious: return "serious"
  case .critical: return "critical"
  @unknown default: return "unknown"
  }
}

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

/// Effective QoS reported by the worker threads themselves.
///
/// What a thread *asked* for and what it *has* can differ, so this reads back
/// from inside each worker rather than trusting the request.
final class WorkerQoSReport: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [String: Int] = [:]

  func record(_ description: String) {
    lock.lock()
    seen[description, default: 0] += 1
    lock.unlock()
  }

  var summary: [String] {
    lock.lock()
    defer { lock.unlock() }
    return seen.sorted { $0.key < $1.key }.map { "\($0.value)x \($0.key)" }
  }
}

// MARK: - Run

let cores = ProcessInfo.processInfo.activeProcessorCount
let half = cores / 2
let role = taskRole()
let startThermal = thermalName(ProcessInfo.processInfo.thermalState)
let startLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
let isTTY = isatty(STDOUT_FILENO) == 1
let parent = parentProcessName()
let darwinPriority = getpriority(PRIO_DARWIN_PROCESS, 0)

var mainQoS = qos_class_t(rawValue: 0)
var mainRelative: Int32 = 0
pthread_get_qos_class_np(pthread_self(), &mainQoS, &mainRelative)

let workerQoS = WorkerQoSReport()
let stop = StopFlag()
var workers: [Thread] = []

func spawnWorker() {
  let thread = Thread {
    pthread_set_qos_class_self_np(qos, 0)

    // Read back what the thread actually has, not what it asked for.
    var effective = qos_class_t(rawValue: 0)
    var relative: Int32 = 0
    pthread_get_qos_class_np(pthread_self(), &effective, &relative)
    workerQoS.record("\(qosName(effective)) rel \(relative)")

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

// Baseline before any load, so the series can be read as a delta.
var previous = readTicks()
Thread.sleep(forTimeInterval: 3)
var current = readTicks()
let baseline = busy(from: previous, to: current)
let baselineE = baseline.prefix(half).reduce(0, +) / Double(half)
let baselineP = baseline.dropFirst(half).reduce(0, +) / Double(cores - half)

// Either all at once, or spread over the stagger window. A simultaneous burst
// of runnable threads may look different to the scheduler than a gradual ramp.
if staggerSeconds <= 0 {
  for _ in 0..<threadCount { spawnWorker() }
}

// Give the workers a moment to report their effective QoS before it is
// printed with the rest of the diagnostics.
if staggerSeconds <= 0 { Thread.sleep(forTimeInterval: 0.2) }

func diagnosticLines() -> [(String, String)] {
  [
    ("logicalCPUs", "\(cores), assuming cpu0-\(half - 1) are efficiency cores"),
    ("taskRole", role.name),
    ("mainThreadQoS", "\(qosName(mainQoS)) rel \(mainRelative)"),
    ("workerQoS", workerQoS.summary.isEmpty ? "not yet spawned" : workerQoS.summary.joined(separator: ", ")),
    ("threadLatencyTier", threadLatencyTier()),
    ("darwinProcessPriority", "\(darwinPriority) (1 means throttled)"),
    ("thermalStateAtStart", startThermal),
    ("lowPowerModeAtStart", startLowPower ? "on" : "off"),
    ("stdoutIsTTY", isTTY ? "yes" : "no"),
    ("parentProcess", parent),
    ("requestedQoS", qosName),
    ("threads", "\(threadCount)"),
    ("seconds", "\(durationSeconds)"),
    ("staggerSeconds", "\(staggerSeconds)"),
    ("baselineE", String(format: "%.1f%%", baselineE * 100)),
    ("baselineP", String(format: "%.1f%%", baselineP * 100)),
  ]
}

var samples: [[String: Any]] = []

if !emitJSON {
  print("# scheduling context")
  for (key, value) in diagnosticLines() {
    print("#   \(key.padding(toLength: 22, withPad: " ", startingAt: 0)) \(value)")
  }
  var header = ["t"]
  header += (0..<cores).map { "cpu\($0)" }
  header += ["E_mean", "P_mean", "threads"]
  print(header.joined(separator: "\t"))
}

let staggerInterval = staggerSeconds > 0 ? Double(staggerSeconds) / Double(threadCount) : 0
var nextSpawnAt = 0.0

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

  if emitJSON {
    samples.append([
      "t": second + 1,
      "perCore": sample.map { ($0 * 1000).rounded() / 10 },
      "eMean": (eMean * 1000).rounded() / 10,
      "pMean": (pMean * 1000).rounded() / 10,
      "threads": workers.count,
    ])
  } else {
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
}

stop.stop()
for worker in workers { while !worker.isFinished { usleep(2_000) } }

let endThermal = thermalName(ProcessInfo.processInfo.thermalState)
let endLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

if emitJSON {
  var diagnostics: [String: Any] = [:]
  for (key, value) in diagnosticLines() { diagnostics[key] = value }
  diagnostics["taskRoleValue"] = Int(role.value)
  diagnostics["thermalStateAtEnd"] = endThermal
  diagnostics["lowPowerModeAtEnd"] = endLowPower ? "on" : "off"

  let root: [String: Any] = ["diagnostics": diagnostics, "samples": samples]
  if let data = try? JSONSerialization.data(
    withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
    print(String(decoding: data, as: UTF8.self))
  }
} else {
  print("#   thermalStateAtEnd      \(endThermal)")
  print("#   lowPowerModeAtEnd      \(endLowPower ? "on" : "off")")
  print("#   workerQoSFinal         \(workerQoS.summary.joined(separator: ", "))")
  print("# done")
}
