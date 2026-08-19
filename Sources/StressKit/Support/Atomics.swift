import CStressAtomics
import Foundation

/// A relaxed atomic 64-bit word.
///
/// Used for the two values a worker thread reads on every duty cycle: its
/// target duty cycle and the run flag. Reference semantics so every worker sees
/// the same storage without capturing a lock.
final class AtomicUInt64: @unchecked Sendable {
  private let storage: UnsafeMutablePointer<UInt64>

  init(_ initialValue: UInt64 = 0) {
    storage = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    storage.initialize(to: initialValue)
  }

  deinit {
    storage.deinitialize(count: 1)
    storage.deallocate()
  }

  /// Relaxed load. Correct for values where a cycle of staleness does not
  /// matter, which is the case for the duty cycle target.
  func load() -> UInt64 { stressd_atomic_load_u64(storage) }

  func store(_ value: UInt64) { stressd_atomic_store_u64(storage, value) }

  @discardableResult
  func add(_ value: UInt64) -> UInt64 { stressd_atomic_add_u64(storage, value) }

  /// Sequentially consistent load, for the run flag: a worker must never miss
  /// a shutdown request.
  func loadOrdered() -> UInt64 { stressd_atomic_load_seq_u64(storage) }

  func storeOrdered(_ value: UInt64) { stressd_atomic_store_seq_u64(storage, value) }
}

/// A relaxed atomic `Double`, stored as its bit pattern.
///
/// Exact: a duty cycle written by `adjust` is the duty cycle the worker reads,
/// with no quantisation.
final class AtomicDouble: @unchecked Sendable {
  private let word: AtomicUInt64

  init(_ initialValue: Double = 0) {
    word = AtomicUInt64(initialValue.bitPattern)
  }

  func load() -> Double { Double(bitPattern: word.load()) }

  func store(_ value: Double) { word.store(value.bitPattern) }
}

/// A relaxed atomic flag.
final class AtomicFlag: @unchecked Sendable {
  private let word: AtomicUInt64

  init(_ initialValue: Bool = false) {
    word = AtomicUInt64(initialValue ? 1 : 0)
  }

  var value: Bool {
    get { word.loadOrdered() != 0 }
    set { word.storeOrdered(newValue ? 1 : 0) }
  }
}
