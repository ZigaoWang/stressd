// Relaxed 64-bit atomics for the synthetic worker hot path.
//
// Swift's `Synchronization.Atomic` is macOS 15 or newer and stressd targets
// macOS 14, so the primitive comes from C11 instead. This is a header-only
// target with no external dependency: `swift-argument-parser` remains the only
// package the project depends on.
//
// Relaxed ordering is deliberate. The only shared values are a duty cycle and
// a run flag; workers re-read them once per ~5 ms cycle and a cycle of staleness
// is irrelevant. What matters is that the reads and writes are not torn and
// are not hoisted out of the loop by the optimiser, which is exactly what
// atomic access guarantees and what a plain `UnsafeMutablePointer` does not.

#ifndef CSTRESS_ATOMICS_H
#define CSTRESS_ATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

/// Loads a 64-bit word atomically with relaxed ordering.
///
/// `pointer` must be 8-byte aligned, which `UnsafeMutablePointer<UInt64>`
/// allocation guarantees.
static inline uint64_t stressd_atomic_load_u64(const uint64_t *pointer) {
  return atomic_load_explicit((const _Atomic(uint64_t) *)pointer, memory_order_relaxed);
}

/// Stores a 64-bit word atomically with relaxed ordering.
static inline void stressd_atomic_store_u64(uint64_t *pointer, uint64_t value) {
  atomic_store_explicit((_Atomic(uint64_t) *)pointer, value, memory_order_relaxed);
}

/// Adds to a 64-bit word atomically, returning the previous value.
///
/// Used for worker counters that are aggregated across threads, where relaxed
/// ordering is enough because nothing is published through them.
static inline uint64_t stressd_atomic_add_u64(uint64_t *pointer, uint64_t value) {
  return atomic_fetch_add_explicit((_Atomic(uint64_t) *)pointer, value, memory_order_relaxed);
}

/// Sequentially consistent store, for the run flag that gates thread shutdown.
static inline void stressd_atomic_store_seq_u64(uint64_t *pointer, uint64_t value) {
  atomic_store_explicit((_Atomic(uint64_t) *)pointer, value, memory_order_seq_cst);
}

/// Sequentially consistent load, paired with `stressd_atomic_store_seq_u64`.
static inline uint64_t stressd_atomic_load_seq_u64(const uint64_t *pointer) {
  return atomic_load_explicit((const _Atomic(uint64_t) *)pointer, memory_order_seq_cst);
}

#endif /* CSTRESS_ATOMICS_H */
