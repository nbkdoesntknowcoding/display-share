import Foundation

/// Decides the encoder's target bitrate from what the receiver reports.
///
/// Kept as a pure function of its inputs — no clocks, no I/O — so the policy can
/// be tested deterministically instead of by staring at a congested network.
///
/// POLICY, and the reasoning behind each choice:
///
/// * **Down fast, up slow.** Congestion is costing the user latency right now,
///   so a bad signal cuts the bitrate multiplicatively. Recovery is additive and
///   requires a run of clean samples, because probing upward too eagerly just
///   re-congests the link and oscillates.
/// * **Sustained, not instantaneous.** A single RTT spike is normal on Wi-Fi.
///   Only `samplesBeforeDecrease` consecutive bad samples trigger a cut.
/// * **Cooldown after every change.** A bitrate change takes a second or two to
///   show up in the receiver's reports; reacting before then would compound.
/// * **Frames are dropped, never buffered.** This controller only sets quality.
///   Queue depth is bounded elsewhere (FrameQueue drops oldest, sends are
///   `.idempotent`), so congestion degrades sharpness — it does not accumulate
///   lag. That division of responsibility is the point.
public struct AdaptiveBitrateController: Sendable {

    public struct Limits: Sendable {
        public var minimum: Int
        public var maximum: Int
        public init(minimum: Int = 1_500_000, maximum: Int = 20_000_000) {
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    public struct Thresholds: Sendable {
        /// Round trip above this is treated as congestion.
        public var congestedRoundTripMillis: Double = 120
        /// Round trip below this counts as clear.
        public var clearRoundTripMillis: Double = 60
        /// Receiver-side drop fraction above this is congestion.
        public var congestedDropRate: Double = 0.05
        public var clearDropRate: Double = 0.01
        public var samplesBeforeDecrease: Int = 3
        public var samplesBeforeIncrease: Int = 8
        /// Multiplicative cut, applied per decision.
        public var decreaseFactor: Double = 0.7
        /// Additive-ish rise: 12% of current per decision.
        public var increaseFactor: Double = 1.12
        /// Seconds to wait after a change before deciding again.
        public var cooldown: TimeInterval = 2.0
        public init() {}
    }

    public struct Sample: Sendable {
        public var roundTripMillis: Double
        public var dropRate: Double
        public var at: Date
        public init(roundTripMillis: Double, dropRate: Double, at: Date) {
            self.roundTripMillis = roundTripMillis
            self.dropRate = dropRate
            self.at = at
        }
    }

    public enum Decision: Equatable, Sendable {
        case hold
        case decrease(to: Int)
        case increase(to: Int)
    }

    public private(set) var currentBitrate: Int
    public private(set) var consecutiveCongested = 0
    public private(set) var consecutiveClear = 0
    public private(set) var lastChange: Date?

    public let limits: Limits
    public var thresholds: Thresholds

    public init(
        startingBitrate: Int = 12_000_000,
        limits: Limits = Limits(),
        thresholds: Thresholds = Thresholds()
    ) {
        self.limits = limits
        self.thresholds = thresholds
        self.currentBitrate = min(max(startingBitrate, limits.minimum), limits.maximum)
    }

    private func isCongested(_ sample: Sample) -> Bool {
        // A zero RTT means "not measured yet", not "perfect link".
        let rttBad = sample.roundTripMillis > 0
            && sample.roundTripMillis > thresholds.congestedRoundTripMillis
        return rttBad || sample.dropRate > thresholds.congestedDropRate
    }

    private func isClear(_ sample: Sample) -> Bool {
        let rttOK = sample.roundTripMillis <= 0
            || sample.roundTripMillis < thresholds.clearRoundTripMillis
        return rttOK && sample.dropRate < thresholds.clearDropRate
    }

    /// Feeds one receiver report and returns what to do.
    public mutating func ingest(_ sample: Sample) -> Decision {
        if isCongested(sample) {
            consecutiveCongested += 1
            consecutiveClear = 0
        } else if isClear(sample) {
            consecutiveClear += 1
            consecutiveCongested = 0
        } else {
            // Between the thresholds: hysteresis band, hold position and let
            // neither counter run away.
            consecutiveCongested = 0
            consecutiveClear = 0
            return .hold
        }

        if let lastChange, sample.at.timeIntervalSince(lastChange) < thresholds.cooldown {
            return .hold
        }

        if consecutiveCongested >= thresholds.samplesBeforeDecrease {
            let target = max(
                limits.minimum, Int((Double(currentBitrate) * thresholds.decreaseFactor).rounded()))
            guard target < currentBitrate else { return .hold }
            currentBitrate = target
            consecutiveCongested = 0
            lastChange = sample.at
            return .decrease(to: target)
        }

        if consecutiveClear >= thresholds.samplesBeforeIncrease {
            let target = min(
                limits.maximum, Int((Double(currentBitrate) * thresholds.increaseFactor).rounded()))
            guard target > currentBitrate else { return .hold }
            currentBitrate = target
            consecutiveClear = 0
            lastChange = sample.at
            return .increase(to: target)
        }

        return .hold
    }
}
