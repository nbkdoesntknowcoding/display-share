import SwiftUI

/// What the popover says about the session, and the colour it says it in
/// (Command 6 of the UI/UX audit).
///
/// The audit found the popover showing a GREEN dot beside `0.0 Mbps` while the
/// Windows client was being refused — green meaning live, next to a number
/// meaning nothing is flowing. It also rendered `Display 0xb`, a raw
/// `CGDirectDisplayID`, to a user.
///
/// The rule this type exists to enforce: **`live` green appears only when frames
/// are actually reaching a receiver.** Running is not streaming, and a session
/// with nobody attached is waiting, not healthy.
///
/// The mapping is a pure function of state so it can be tested. Every previous
/// defect of this kind — the dishonest dot included — was invisible until
/// something exercised the assembled result.
public enum SessionStatus: Equatable, Sendable {
    case idle
    case starting
    /// Sharing is up, but no receiver has attached.
    case waiting
    /// A receiver is attached and frames are flowing.
    case streaming(client: String?)
    /// Attached, but the link is struggling and quality has been reduced.
    case degraded(client: String?)
    case failed(String)

    public var headline: String {
        switch self {
        case .idle: return "Not sharing"
        case .starting: return "Starting…"
        case .waiting: return "Waiting for a device"
        case .streaming(let client): return "Sharing to \(client ?? "your PC")"
        case .degraded: return "Connection is unstable"
        case .failed: return "Disconnected"
        }
    }

    public var detail: String? {
        switch self {
        case .idle: return "Press Start to begin"
        case .starting: return nil
        case .waiting: return "Open Display Share on your PC"
        case .streaming: return nil
        case .degraded: return "Reduced quality to keep up"
        case .failed(let reason): return reason
        }
    }

    /// Metrics belong to a live stream only. Showing them while waiting is how
    /// `0.0 Mbps` ended up sitting beside a green dot.
    public var showsMetrics: Bool {
        switch self {
        case .streaming, .degraded: return true
        default: return false
        }
    }

    /// Whether the dot should pulse — used for the two states that mean
    /// "something is expected to change shortly".
    public var pulses: Bool {
        switch self {
        case .waiting, .starting: return true
        default: return false
        }
    }
}

extension SessionStatus {
    /// Derives the status from what the app actually knows.
    ///
    /// `connected` and `megabitsPerSecond` are both required for `streaming`,
    /// because a socket can be attached while nothing flows — precisely the
    /// state the old green dot misreported.
    public static func derive(
        isActive: Bool,
        isStarting: Bool,
        failure: String?,
        connected: Bool,
        megabitsPerSecond: Double,
        client: String?,
        droppedFrames: Int
    ) -> SessionStatus {
        if let failure { return .failed(failure) }
        if isStarting { return .starting }
        guard isActive else { return .idle }
        guard connected else { return .waiting }
        // Attached but nothing arriving is not healthy, whatever the socket says.
        guard megabitsPerSecond > 0.05 else { return .waiting }
        if droppedFrames > 0 { return .degraded(client: client) }
        return .streaming(client: client)
    }
}

/// The status row: a state dot, a headline, and — only while streaming — metrics.
public struct StatusPill: View {
    private let status: SessionStatus
    private let fps: Double
    private let megabitsPerSecond: Double
    private let latencyMillis: Double
    /// Seconds since the last sample arrived. Metrics grey out past two seconds
    /// rather than presenting a stale number as current.
    private let sampleAge: TimeInterval

    @State private var pulsing = false

    public init(
        status: SessionStatus,
        fps: Double = 0,
        megabitsPerSecond: Double = 0,
        latencyMillis: Double = 0,
        sampleAge: TimeInterval = 0
    ) {
        self.status = status
        self.fps = fps
        self.megabitsPerSecond = megabitsPerSecond
        self.latencyMillis = latencyMillis
        self.sampleAge = sampleAge
    }

    private var dotColor: Color {
        switch status {
        case .idle: return DSColor.textFaint
        case .starting, .waiting: return DSColor.textMuted
        // The hard rule: live green means frames are reaching a receiver.
        case .streaming: return DSColor.live
        case .degraded: return DSColor.warn
        case .failed: return DSColor.error
        }
    }

    private var stale: Bool { sampleAge > 2 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .offset(y: -1)
                    .opacity(status.pulses && pulsing ? 0.35 : 1)
                    .animation(
                        status.pulses
                            ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
                            : .default,
                        value: pulsing
                    )
                Text(status.headline)
                    .font(.system(size: DSFont.f3, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let detail = status.detail {
                Text(detail)
                    .font(.system(size: DSFont.f2))
                    .foregroundStyle(DSColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }

            if status.showsMetrics {
                Text(metricsLine)
                    .font(.system(size: DSFont.f2, design: .monospaced))
                    .monospacedDigit()
                    // Stale numbers read as current unless they are visibly dimmed.
                    .foregroundStyle(stale ? DSColor.textFaint : DSColor.textMuted)
                    .padding(.leading, 14)
                    .accessibilityLabel(
                        "\(Int(fps.rounded())) frames per second, "
                            + String(format: "%.1f megabits per second, ", megabitsPerSecond)
                            + String(format: "%.1f milliseconds latency", latencyMillis)
                    )
            }
        }
        .onAppear { pulsing = status.pulses }
        .onChange(of: status.pulses) { _, next in pulsing = next }
        .accessibilityElement(children: .combine)
    }

    /// Rounded the way the audit specifies: frames whole, the rest to one place.
    /// More precision than that is noise on a number that changes every second.
    private var metricsLine: String {
        String(
            format: "%d fps   ·   %.1f Mbps   ·   %.1f ms",
            Int(fps.rounded()), megabitsPerSecond, latencyMillis
        )
    }
}
