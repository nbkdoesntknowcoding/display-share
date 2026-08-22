import Foundation

/// What the sender can actually observe about the link.
///
/// Until now the controller steered on one number: `now - echoed`, the time
/// since the sender minted the timestamp of the newest frame the receiver has.
/// That number has two problems, and the second one is a bug users feel.
///
/// **It measures the wrong thing.** Lowering the bitrate can relieve *queueing*
/// — bytes waiting because the link cannot carry them — and can do nothing at
/// all about propagation. A link that is 200ms away but keeps up perfectly is
/// not congested, and cutting quality does not bring it closer. Absolute delay
/// conflates the two; backlog separates them.
///
/// **It counts the sender's own silence as the link's fault.** ScreenCaptureKit
/// delivers nothing while the desktop is still — those frames arrive marked as
/// carrying no new pixels and are discarded before the queue. So an idle desktop
/// sends no video, the receiver's echo stops advancing, and `now - echoed`
/// climbs by a second for every second nobody touches the machine. Past 120ms
/// it reads as congestion; three reports later the bitrate is cut, and it is cut
/// again every cooldown until it reaches the floor. Come back to a machine left
/// alone for a minute and the picture is at 1.5 Mbps, then takes a sustained
/// clean run to climb back. Nothing about that is visible while it happens: the
/// link was fine the entire time.
///
/// So this measures **backlog** — how much video the receiver has not caught up
/// with, in the sender's own clock. Nothing was sent while idle, so there is
/// nothing to be behind on, and the signal is zero.
///
/// One signal is not enough, though, because backlog has its own blind spot: a
/// link that has stopped taking bytes entirely produces no *new* sends, so the
/// receiver eventually acknowledges the last frame that got through and the
/// backlog reads zero — at the exact moment the link is worst. `shedRate`
/// covers that: frames the send gate refused because the socket would not take
/// them are evidence gathered entirely on this machine, and stay true when the
/// receiver's own numbers have gone stale.
///
/// It is not independent of the receiver *existing*, to be clear — every signal
/// here is evaluated when a report arrives, and a connection that has died
/// completely produces no reports and is torn down instead. What shed rate
/// survives is the common case: video backing up while the small control
/// messages still get through, where the receiver is answering but its answers
/// describe a stream it is no longer being given.
public struct CongestionSignal: Sendable, Equatable {

    /// Milliseconds of video the receiver has not acknowledged yet.
    ///
    /// Measured entirely in the sender's clock: both ends of the subtraction are
    /// timestamps this machine minted, so the receiver's clock never enters into
    /// it and there is no offset to cancel.
    public var backlogMillis: Double

    /// Fraction of frames the send gate shed because the socket was full.
    ///
    /// The most direct evidence available: no interpretation of anything the
    /// receiver said, just bytes this machine's own network stack refused.
    public var shedRate: Double

    /// Frames waiting in the receiver's decoder.
    ///
    /// Distinct from network backlog: this is a receiver that took the bytes and
    /// cannot decode them fast enough. Lowering the bitrate helps here too —
    /// smaller frames are cheaper to decode — but the cause is different and
    /// worth telling apart when reading the logs.
    public var decodeQueueDepth: Int

    /// Fraction of frames the receiver failed to decode.
    public var receiverDropRate: Double

    public init(
        backlogMillis: Double = 0,
        shedRate: Double = 0,
        decodeQueueDepth: Int = 0,
        receiverDropRate: Double = 0
    ) {
        self.backlogMillis = backlogMillis
        self.shedRate = shedRate
        self.decodeQueueDepth = decodeQueueDepth
        self.receiverDropRate = receiverDropRate
    }

    /// How far behind the receiver is, from the newest frame sent and the
    /// newest it has acknowledged.
    ///
    /// Both are timestamps this sender minted, so this is a subtraction within
    /// one clock rather than a comparison between two.
    public static func backlogMillis(newestSent: UInt64, echoed: UInt64) -> Double {
        // Caught up — or ahead, which means an echo we never sent. Either way
        // there is no backlog, and a negative one is not a measurement.
        guard newestSent > echoed else { return 0 }
        return Double(newestSent - echoed) / 1000
    }
}

/// Whether backlog is building, rather than whether it is currently large.
///
/// A threshold alone cannot fire until the delay has already been paid. By the
/// time backlog crosses 120ms the user has been watching it grow for a second,
/// and a controller that waits for the crossing is always reacting to lag that
/// has already been felt. What matters is the direction: backlog rising
/// steadily means the link is taking less than it is being given, and that is
/// true long before any particular threshold.
///
/// This is the one idea worth borrowing from Google Congestion Control, which
/// estimates a trend rather than testing a level. It is not GCC: no Kalman
/// filter, no adaptive threshold, no arrival-time model — a least-squares slope
/// over the last few reports. GCC makes ten to twenty decisions a second from
/// per-packet arrival times; this sees a report every 500ms, so the elaborate
/// machinery has nothing to work with. The direction survives the simplification;
/// the rest of GCC would be cargo.
public struct BacklogTrend: Sendable {

    /// How many reports the slope is fitted over. Six reports is about three
    /// seconds — long enough that one bad sample cannot define a trend, short
    /// enough to still be describing now.
    public let window: Int

    private var samples: [(seconds: TimeInterval, backlogMillis: Double)] = []
    private var origin: Date?

    public init(window: Int = 6) {
        precondition(window >= 3, "a slope needs at least three points to mean anything")
        self.window = window
    }

    public mutating func note(backlogMillis: Double, at moment: Date) {
        let origin = origin ?? moment
        if self.origin == nil { self.origin = origin }
        samples.append((moment.timeIntervalSince(origin), backlogMillis))
        if samples.count > window { samples.removeFirst() }
    }

    /// Milliseconds of backlog added per second. Positive means building.
    ///
    /// `nil` until there is enough to fit, and when every sample shares a
    /// timestamp — a vertical line has no slope, and inventing one from a
    /// division by zero would report an infinite trend.
    public var slopeMillisPerSecond: Double? {
        guard samples.count >= 3 else { return nil }

        let n = Double(samples.count)
        let meanX = samples.reduce(0) { $0 + $1.seconds } / n
        let meanY = samples.reduce(0) { $0 + $1.backlogMillis } / n

        var covariance = 0.0
        var variance = 0.0
        for sample in samples {
            let dx = sample.seconds - meanX
            covariance += dx * (sample.backlogMillis - meanY)
            variance += dx * dx
        }
        guard variance > 0 else { return nil }
        return covariance / variance
    }

    /// Forgets everything. A reconnect starts a new link, and a slope fitted
    /// across the gap describes neither.
    public mutating func reset() {
        samples.removeAll()
        origin = nil
    }
}
