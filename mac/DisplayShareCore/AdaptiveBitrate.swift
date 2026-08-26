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
///   Queue depth is bounded elsewhere — `FrameQueue` drops oldest before the
///   encoder, and `SendGate` sheds frames after it rather than let the encoder
///   run ahead of the socket — so congestion degrades sharpness and it does not
///   accumulate lag. That division of responsibility is the point, and it is
///   load-bearing for everything below: this controller reads round-trip time,
///   which only reports congestion honestly while nothing downstream is
///   silently queueing.
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
        /// Backlog above this is treated as congestion.
        ///
        /// Milliseconds of video the receiver has not caught up with — not
        /// round-trip time, which counted the sender's own idle desktop as the
        /// link's fault. See `CongestionSignal`.
        public var congestedBacklogMillis: Double = 120
        /// Backlog below this counts as clear.
        public var clearBacklogMillis: Double = 60
        /// Fraction of frames the send gate shed because the socket was full.
        ///
        /// Deliberately tighter than the receiver's drop rate. A shed frame is
        /// this machine failing to hand bytes to its own network stack, which
        /// is unambiguous; a receiver drop can be a decode error with an
        /// entirely different cause.
        public var congestedShedRate: Double = 0.02
        public var clearShedRate: Double = 0.005
        /// Receiver-side drop fraction above this is congestion.
        public var congestedDropRate: Double = 0.05
        public var clearDropRate: Double = 0.01
        /// Frames waiting in the receiver's decoder before it counts as behind.
        ///
        /// One or two in flight is normal pipelining. A queue that keeps
        /// growing is a decoder that will never catch up, because nothing
        /// downstream drains faster than real time.
        public var congestedDecodeQueue: Int = 4
        public var clearDecodeQueue: Int = 2
        /// Backlog growth, in milliseconds per second, that counts as building.
        ///
        /// Reacting to the direction rather than the level: by the time backlog
        /// crosses the congested threshold the delay has already been paid.
        ///
        /// There is deliberately no accompanying "ignore small backlogs" floor,
        /// which is the first thing a reader will look for. It would be dead
        /// code. Sustaining this slope across the trend's window means backlog
        /// rising by roughly `window x interval x slope` — about 75ms at the
        /// current report cadence — so anything that holds the slope for the
        /// three consecutive samples a cut requires has already left any
        /// plausible noise band behind. A floor was written, tested, and found
        /// to change no decision; it is not here because it did nothing, not
        /// because the question was missed.
        public var buildingSlopeMillisPerSecond: Double = 25
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
        public var signal: CongestionSignal
        public var at: Date
        public init(signal: CongestionSignal, at: Date) {
            self.signal = signal
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
    /// Whether backlog was building at the last decision, for the log line that
    /// explains why the bitrate moved.
    public private(set) var backlogSlope: Double?
    private var trend = BacklogTrend()

    public let limits: Limits
    public var thresholds: Thresholds

    /// Forgets the link. A reconnect is a different path, and a trend fitted
    /// across the gap describes neither side of it.
    public mutating func resetLink() {
        trend.reset()
        backlogSlope = nil
        consecutiveCongested = 0
        consecutiveClear = 0
        lastChange = nil
    }

    public init(
        startingBitrate: Int = 12_000_000,
        limits: Limits = Limits(),
        thresholds: Thresholds = Thresholds()
    ) {
        self.limits = limits
        self.thresholds = thresholds
        self.currentBitrate = min(max(startingBitrate, limits.minimum), limits.maximum)
    }

    /// Backlog rising fast enough to be worth acting on before it is large.
    private func isBuilding() -> Bool {
        guard let slope = backlogSlope else { return false }
        return slope > thresholds.buildingSlopeMillisPerSecond
    }

    /// Any one of these is enough.
    ///
    /// They are deliberately not combined into a score. Each describes a
    /// different failure, each is sufficient on its own, and a weighted sum
    /// would let two half-signals average away into silence — which is exactly
    /// the case where something is wrong.
    private func isCongested(_ sample: Sample) -> Bool {
        let signal = sample.signal
        return signal.backlogMillis > thresholds.congestedBacklogMillis
            || signal.shedRate > thresholds.congestedShedRate
            || signal.receiverDropRate > thresholds.congestedDropRate
            || signal.decodeQueueDepth > thresholds.congestedDecodeQueue
            || isBuilding()
    }

    /// All of them, and not building.
    ///
    /// Asymmetric with `isCongested` on purpose: one bad signal is enough to
    /// cut, and every signal must agree before climbing. The cost of being
    /// wrong is not symmetric either — cutting too eagerly costs sharpness,
    /// climbing too eagerly costs the latency this whole controller exists to
    /// protect.
    private func isClear(_ sample: Sample) -> Bool {
        let signal = sample.signal
        return signal.backlogMillis < thresholds.clearBacklogMillis
            && signal.shedRate < thresholds.clearShedRate
            && signal.receiverDropRate < thresholds.clearDropRate
            && signal.decodeQueueDepth <= thresholds.clearDecodeQueue
            && !isBuilding()
    }

    /// Feeds one receiver report and returns what to do.
    public mutating func ingest(_ sample: Sample) -> Decision {
        // Noted before any decision, so the slope covers this report too.
        trend.note(backlogMillis: sample.signal.backlogMillis, at: sample.at)
        backlogSlope = trend.slopeMillisPerSecond

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
