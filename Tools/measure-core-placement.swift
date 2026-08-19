#!/usr/bin/env swift
//
// Where does the scheduler actually put threads of a given QoS class?
//
// Run from an ordinary interactive Terminal on an otherwise-idle machine:
//
//     swift Tools/measure-core-placement.swift
//
// Prints per-logical-CPU utilization for a fixed number of spinning threads at
// each QoS class. On Apple silicon logical CPUs are numbered efficiency cores
// first, so a low-numbered block lighting up means the work landed on E-cores.
//
// This exists because an earlier claim in this project — that .userInteractive
// biases work onto performance cores — did not survive measurement. See
// docs/mechanisms.md section 3.

import Darwin
import Foundation

func ticks() -> [[UInt32]] {
  var cpuCount: natural_t = 0
  var info: processor_info_array_t?
  var infoCount: mach_msg_type_number_t = 0
  host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
  guard let info else { return [] }
  defer {
    vm_deallocate(
      mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * 4))
  }
  return (0..<Int(cpuCount)).map { cpu in (0..<4).map { UInt32(bitPattern: info[cpu * 4 + $0]) } }
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

func measure(label: String, qos: qos_class_t, threads: Int) {
  let stop = StopFlag()
  var workers: [Thread] = []
  for _ in 0..<threads {
    let thread = Thread {
      pthread_set_qos_class_self_np(qos, 0)
      var x = 1.0
      while !stop.isStopped() {
        for _ in 0..<100_000 { x = x * 0.999_999 + 0.000_001 }
        if x < -1e9 { print(x) }
      }
    }
    thread.qualityOfService =
      qos == QOS_CLASS_BACKGROUND ? .background : .userInteractive
    thread.start()
    workers.append(thread)
  }

  Thread.sleep(forTimeInterval: 3)
  let before = ticks()
  Thread.sleep(forTimeInterval: 5)
  let after = ticks()
  stop.stop()
  for worker in workers { while !worker.isFinished { usleep(2_000) } }

  let busy = (0..<before.count).map { cpu -> Double in
    let delta = (0..<4).map { Double(after[cpu][$0] &- before[cpu][$0]) }
    let total = delta.reduce(0, +)
    return total > 0 ? (total - delta[2]) / total : 0
  }
  print("\n\(label), \(threads) threads")
  for (cpu, value) in busy.enumerated() {
    let bar = String(repeating: "#", count: Int(value * 40))
    print(String(format: "  cpu%-2d %-40@ %5.1f%%", cpu, bar as NSString, value * 100))
  }
  Thread.sleep(forTimeInterval: 5)
}

let cores = ProcessInfo.processInfo.activeProcessorCount
print("logical CPUs: \(cores)   (efficiency cores are numbered first)")
print("PRIO_DARWIN_PROCESS = \(getpriority(PRIO_DARWIN_PROCESS, 0))  (1 means throttled)")

measure(label: "userInteractive", qos: QOS_CLASS_USER_INTERACTIVE, threads: cores / 2)
measure(label: "userInteractive", qos: QOS_CLASS_USER_INTERACTIVE, threads: cores)
measure(label: "background", qos: QOS_CLASS_BACKGROUND, threads: cores / 2)
