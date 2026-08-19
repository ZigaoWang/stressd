import Foundation

/// Tuning for the mixing loop.
public struct MixerConfiguration: Sendable, Equatable, Codable {

  /// Most the synthetic duty cycle may move per second, as a fraction.
  ///
  /// BOINC's utilization steps sharply when a workunit finishes and another
  /// starts. Without a slew limit a proportional controller chases each step
  /// and overshoots it, then chases its own overshoot: the classic oscillation.
  /// 10 points per second closes a full-scale gap in ten seconds, which is fast
  /// enough to track real changes and far too slow to ring.
  public var slewRatePerSecond: Double

  /// Errors smaller than this are ignored.
  ///
  /// Utilization measured over a one second window is noisy by a point or two
  /// on its own. Reacting to that noise would mean never sitting still, and
  /// every correction is itself a disturbance.
  public var deadband: Double

  /// Proportional gain. 1.0 means "ask for exactly the observed shortfall",
  /// which combined with the slew limit converges without integral windup.
  public var gain: Double

  public var interval: TimeInterval

  public init(
    slewRatePerSecond: Double = 0.10,
    deadband: Double = 0.03,
    gain: Double = 1.0,
    interval: TimeInterval = 1.0
  ) {
    self.slewRatePerSecond = max(0.001, slewRatePerSecond)
    self.deadband = max(0, deadband)
    self.gain = max(0.01, gain)
    self.interval = max(0.1, interval)
  }
}

/// One step's decision.
public struct MixerDecision: Sendable, Equatable {
  /// Duty cycle to hand the synthetic source.
  public let syntheticDuty: Double
  /// True when contributed load alone already exceeds the target, so synthetic
  /// is at zero and the contributed source must be dialled back instead.
  public let contributedOverTarget: Bool
  /// Suggested contributed share when it has to be reduced.
  public let contributedTarget: Double?
  /// Error the controller saw, before the deadband and slew limit.
  public let rawError: Double
  /// True when the error was inside the deadband and nothing moved.
  public let withinDeadband: Bool
  /// True when the requested change was clipped by the slew limit.
  public let slewLimited: Bool
}

/// The closed loop that tops contributed load up with synthetic load.
///
/// Pure and synchronous so it can be driven against a simulated BOINC that
/// steps its utilization abruptly, without running any real workers.
///
/// ## What it controls on
///
/// The input is *observed utilization minus the baseline captured before the
/// run started*, not what anything was asked for. Contributed load does not do
/// what it is told: BOINC ramps when a workunit starts and drops to nothing
/// when one finishes, on its own schedule. The only way to hold a total is to
/// measure what is actually happening and make up the difference.
public struct MixerController: Sendable {

  public let configuration: MixerConfiguration
  private(set) public var syntheticDuty: Double

  public init(configuration: MixerConfiguration = MixerConfiguration(), initialDuty: Double = 0) {
    self.configuration = configuration
    self.syntheticDuty = min(max(initialDuty, 0), 1)
  }

  /// Advances the loop one step.
  ///
  /// - Parameters:
  ///   - target: Total load wanted, as a fraction of the whole machine.
  ///   - observedDelta: Measured utilization above the pre-run baseline.
  ///   - contributedUtilization: Measured share attributable to contributed
  ///     sources, above baseline.
  ///   - elapsed: Seconds since the previous step, which bounds the slew.
  /// - Returns: The duty cycle to apply and why, including whether the deadband
  ///   or the slew limit shaped it.
  public mutating func step(
    target: Double,
    observedDelta: Double,
    contributedUtilization: Double,
    elapsed: TimeInterval
  ) -> MixerDecision {
    let target = min(max(target, 0), 1)
    let contributed = min(max(contributedUtilization, 0), 1)

    // Headroom is what is left of the target after contributed work has taken
    // its share. Synthetic is never allowed above it, which is what keeps the
    // total from being oversubscribed even mid-correction.
    let headroom = max(0, target - contributed)
    let contributedOverTarget = contributed > target + configuration.deadband

    let error = target - observedDelta
    let withinDeadband = abs(error) < configuration.deadband

    var desired = syntheticDuty
    if !withinDeadband {
      desired = syntheticDuty + configuration.gain * error
    }
    desired = min(max(desired, 0), 1)
    desired = min(desired, headroom)

    // Slew limit last, so it bounds the change that actually happens rather
    // than one the clamps would have reduced anyway.
    let maximumChange = configuration.slewRatePerSecond * max(elapsed, 0)
    let requestedChange = desired - syntheticDuty
    let slewLimited = abs(requestedChange) > maximumChange
    let appliedChange =
      slewLimited ? (requestedChange > 0 ? maximumChange : -maximumChange) : requestedChange

    syntheticDuty = min(max(syntheticDuty + appliedChange, 0), 1)

    return MixerDecision(
      syntheticDuty: syntheticDuty,
      contributedOverTarget: contributedOverTarget,
      // Only ask the contributed source to back off once synthetic is already
      // at zero. Reducing real work while burning synthetic cycles would be
      // exactly backwards.
      contributedTarget: contributedOverTarget && syntheticDuty <= 0.001 ? target : nil,
      rawError: error,
      withinDeadband: withinDeadband,
      slewLimited: slewLimited)
  }

  /// Resets the controller's state, for when load restarts.
  public mutating func reset(to duty: Double = 0) {
    syntheticDuty = min(max(duty, 0), 1)
  }
}
