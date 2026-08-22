import Foundation

/// Decides whether an encoded access unit goes to the socket now or is shed.
///
/// Kept as a pure state machine — no clocks, no sockets, no locks — so the
/// policy can be tested directly instead of by congesting a real network. The
/// caller owns the lock and supplies the time, exactly as
/// `AdaptiveBitrateController` does.
///
/// WHY THIS EXISTS
///
/// `NWConnection.send` with `.idempotent` installs no completion handler, so it
/// reports nothing back: frames are handed to the stack as fast as the encoder
/// makes them and pile up in the TCP send buffer when the link is slow. Nothing
/// errors and every counter keeps rising, so the stream looks healthy from the
/// application while latency climbs. (`.idempotent` never meant "do not block
/// me" — it means the data is safe to resend, which is what makes it eligible
/// as TCP Fast Open data.) `.contentProcessed` is the documented sender-side
/// back-pressure mechanism: its completion fires when the stack has *consumed*
/// the data, not when it has been transmitted, and the value is that the
/// completion is delayed while the send buffer is full. That delay is the
/// signal this gate reads.
///
/// POLICY, and the reasoning behind each choice:
///
/// * **At most one send outstanding.** Network.framework exposes no way to cap
///   the kernel's unsent backlog — TCP_NOTSENT_LOWAT is absent from
///   `NWProtocolTCP.Options`, as is SO_SNDBUF, and the underlying descriptor is
///   not reachable. Holding a single send in flight bounds the backlog by
///   construction instead: the encoder can never run more than one access unit
///   ahead of the socket.
/// * **Keep the newest.** A frame arriving while a send is outstanding is
///   dropped rather than queued — the same discipline `FrameQueue` applies one
///   stage earlier, for the same reason: a stale frame has no value once a
///   newer one exists, and queueing converts a slow consumer into accumulating
///   lag instead of visible frame loss.
/// * **Repair after every drop.** The wire format carries no sequence number
///   (SPEC §3), so the receiver cannot tell that a frame went missing. Fed a
///   P-frame whose reference is gone its decoder need not error — it typically
///   produces a visibly wrong picture and stays wrong until the next IDR, up to
///   `MaxKeyFrameInterval` (2s) away. So the receiver's
///   `request_keyframe`-on-decode-error path cannot be relied on to repair a
///   frame we shed; the side that dropped it has to ask.
/// * **Rate-limit the repair.** Keyframes are the largest frames on the wire,
///   so forcing one per dropped frame would deepen the very congestion that
///   caused the drop. SPEC §4.5 already fixes the limit for receiver-driven
///   requests at one per 250ms; the same ceiling applies here.
///
/// One consequence worth stating, because it looks like a gap until you follow
/// it through: the repair is raised from `completed(at:)`, so while a link is
/// fully stalled — no completions at all — no IDR is requested. That is the
/// behaviour we want. An IDR minted mid-stall could only be shed like every
/// other frame, and it is the most expensive frame to waste. The owed repair is
/// remembered and goes out on the first completion after the link recovers,
/// which is the first moment it can actually reach the receiver.
public struct SendGate: Sendable {

    public enum Decision: Equatable, Sendable {
        case send
        case drop
    }

    /// SPEC §4.5: at most one forced IDR per 250ms.
    public var minimumKeyframeInterval: TimeInterval

    private var sendOutstanding = false
    /// Set when a frame was shed, cleared only once a repair IDR is actually
    /// requested — see `completed(at:)`.
    private var damaged = false
    private var lastKeyframeRequest: Date?

    public init(minimumKeyframeInterval: TimeInterval = 0.25) {
        self.minimumKeyframeInterval = minimumKeyframeInterval
    }

    /// True while the stack has not yet taken the previous access unit.
    public var isSendOutstanding: Bool { sendOutstanding }

    /// Offers the newest encoded frame to the socket.
    public mutating func offer() -> Decision {
        guard !sendOutstanding else {
            damaged = true
            return .drop
        }
        sendOutstanding = true
        return .send
    }

    /// Call from the send completion. Returns true when the caller should force
    /// an IDR to repair the reference chain a shed frame broke.
    public mutating func completed(at now: Date) -> Bool {
        sendOutstanding = false
        guard damaged else { return false }
        if let last = lastKeyframeRequest,
            now.timeIntervalSince(last) < minimumKeyframeInterval
        {
            // Inside the rate limit. Deliberately leave `damaged` set so the
            // next completion retries: clearing it here would forget the repair
            // and leave the receiver corrupt until the next natural keyframe.
            return false
        }
        damaged = false
        lastKeyframeRequest = now
        return true
    }

    /// A new socket starts clean — no send is outstanding on it and it has
    /// missed nothing.
    public mutating func reset() {
        sendOutstanding = false
        damaged = false
        lastKeyframeRequest = nil
    }
}
