import SwiftUI

/// What the popover contains, and in what order (Command 9 of the UI/UX audit).
///
/// The audit's complaint was structural: a JPEG quality slider — a Phase-1
/// MJPEG artefact in an H.264 product — carried more visual weight than the
/// connection status, and dividers were emitted by whichever block happened to
/// be visible, so two could land back to back or none at all.
///
/// Both problems come from the order living inside a view body, where it is a
/// side effect of which `if` succeeded. Here it is a value: a pure function of
/// what the app knows, which can be asserted rather than eyeballed.
public enum PopoverSection: String, CaseIterable, Sendable {
    /// The mark, the name, and the positioning line.
    case header
    /// Leads, always. The whole point of the reorder.
    case status
    /// A pending PIN — the most important thing on screen while it exists.
    case pairing
    case screenRecordingNotice
    case accessibilityNotice
    /// Resolution and frame rate.
    case display
    case update
    /// The browser fallback, collapsed.
    case browserFallback
    /// Viewing a Windows PC from this Mac, collapsed.
    case otherDirection
    /// Start/Stop and Quit. Always last.
    case actions

    /// The sections present for a given state, in the order they are drawn.
    ///
    /// Every caller renders exactly this, with one divider between neighbours —
    /// so a divider can no longer be attached to a block that may or may not be
    /// there.
    public static func ordered(
        isPairing: Bool,
        needsScreenRecording: Bool,
        needsAccessibility: Bool,
        hasUpdate: Bool,
        hasBrowserFallback: Bool
    ) -> [PopoverSection] {
        var sections: [PopoverSection] = [.header, .status]
        if isPairing { sections.append(.pairing) }
        if needsScreenRecording { sections.append(.screenRecordingNotice) }
        if needsAccessibility { sections.append(.accessibilityNotice) }
        sections.append(.display)
        if hasUpdate { sections.append(.update) }
        if hasBrowserFallback { sections.append(.browserFallback) }
        sections.append(.otherDirection)
        sections.append(.actions)
        return sections
    }
}

/// The popover's vertical rhythm, from the token scale.
public enum DSPopoverMetrics {
    public static let padding: CGFloat = DSSpacing.s4
    public static let dividerMargin: CGFloat = DSSpacing.s3
    public static let sectionSpacing: CGFloat = DSSpacing.s4
    public static let width: CGFloat = 320
}

/// A divider carrying its own margins, so spacing cannot vary by call site.
public struct DSDivider: View {
    public init() {}
    public var body: some View {
        Divider()
            .overlay(DSColor.border)
            .padding(.vertical, DSPopoverMetrics.dividerMargin)
    }
}

/// The app mark: two overlapping displays, one outlined and one filled.
///
/// Drawn from the same geometry as `design/make-icon.swift` — the overlap is
/// the idea, one screen becoming two — so the popover header and the app icon
/// cannot drift apart.
public struct DSAppMark: View {
    private let size: CGFloat

    // The icon's own coordinates, in its 1024 canvas, reduced to the box the
    // two rectangles actually occupy.
    private static let designWidth: CGFloat = 604
    private static let designHeight: CGFloat = 460

    public init(size: CGFloat = 18) {
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / Self.designWidth
            let radius = 54 * scale

            let back = Path(
                roundedRect: CGRect(x: 0, y: 0, width: 430 * scale, height: 330 * scale),
                cornerRadius: radius)
            context.stroke(
                back, with: .color(DSColor.accent.opacity(0.55)), lineWidth: 46 * scale)

            let front = Path(
                roundedRect: CGRect(
                    x: 174 * scale, y: 130 * scale, width: 430 * scale, height: 330 * scale),
                cornerRadius: radius)
            context.fill(front, with: .color(DSColor.accent))
        }
        .frame(width: size, height: size * (Self.designHeight / Self.designWidth))
        .accessibilityHidden(true)
    }
}
