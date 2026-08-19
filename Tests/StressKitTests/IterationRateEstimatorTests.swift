import Testing

@testable import StressKit

@Suite("Iteration rate estimation")
struct IterationRateEstimatorTests {

  @Test("An uncalibrated estimator says so rather than guessing")
  func uncalibrated() {
    let estimator = IterationRateEstimator()
    #expect(!estimator.isCalibrated)
    #expect(estimator.iterations(forNanoseconds: 1_000_000) == nil)
    #expect(estimator.nanoseconds(forIterations: 1000) == nil)
  }

  @Test("The first measurement is taken at face value")
  func firstMeasurementSeedsTheEstimate() {
    var estimator = IterationRateEstimator()
    estimator.record(iterations: 1_000, nanoseconds: 1_000)
    #expect(estimator.iterationsPerNanosecond == 1.0)
    #expect(estimator.iterations(forNanoseconds: 200_000) == 200_000)
  }

  @Test("A sustained frequency change is tracked")
  func tracksFrequencyChange() {
    var estimator = IterationRateEstimator()
    estimator.record(iterations: 1_000, nanoseconds: 1_000)

    // A migration from a P-core to an E-core roughly halves throughput. The
    // estimate has to follow within a handful of chunks or every work window
    // afterwards overshoots.
    for _ in 0..<40 {
      estimator.record(iterations: 500, nanoseconds: 1_000)
    }
    let rate = estimator.iterationsPerNanosecond ?? 0
    #expect(abs(rate - 0.5) < 0.02)
  }

  @Test("A descheduled chunk does not drag the estimate down")
  func rejectsDeschedulingOutliers() {
    var estimator = IterationRateEstimator()
    for _ in 0..<20 {
      estimator.record(iterations: 1_000, nanoseconds: 1_000)
    }
    let before = estimator.iterationsPerNanosecond

    // One chunk that took 100x as long: the thread lost the CPU, it did not
    // suddenly become a hundred times slower.
    estimator.record(iterations: 1_000, nanoseconds: 100_000)
    #expect(estimator.iterationsPerNanosecond == before)
  }

  @Test("A persistently wrong estimate eventually gives way to the measurements")
  func forcedAcceptAfterRepeatedRejections() {
    var estimator = IterationRateEstimator()
    estimator.record(iterations: 1_000_000, nanoseconds: 1_000)

    // If the guard were unconditional, an estimate that starts far too high
    // could never come down.
    for _ in 0..<60 {
      estimator.record(iterations: 1_000, nanoseconds: 1_000)
    }
    let rate = estimator.iterationsPerNanosecond ?? 0
    #expect(rate < 10)
  }

  @Test("Chunk sizes stay within the requested bounds")
  func chunkBounds() {
    var estimator = IterationRateEstimator()
    estimator.record(iterations: 1_000, nanoseconds: 1_000)

    #expect(estimator.iterations(forNanoseconds: 200_000, maximum: 1_000) == 1_000)
    // Never zero: a chunk of no work would spin on the clock.
    #expect(estimator.iterations(forNanoseconds: 0) == 1)
  }

  @Test("Degenerate measurements are ignored")
  func ignoresDegenerateInput() {
    var estimator = IterationRateEstimator()
    estimator.record(iterations: 0, nanoseconds: 1_000)
    estimator.record(iterations: 1_000, nanoseconds: 0)
    #expect(!estimator.isCalibrated)
  }

  @Test("Round trip between iterations and nanoseconds is consistent")
  func roundTrip() {
    var estimator = IterationRateEstimator()
    estimator.record(iterations: 4_000, nanoseconds: 1_000)

    #expect(estimator.iterations(forNanoseconds: 250_000) == 1_000_000)
    #expect(estimator.nanoseconds(forIterations: 1_000_000) == 250_000)
  }
}
