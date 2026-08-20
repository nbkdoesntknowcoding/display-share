import SwiftUI

/// The Mac's one button (Command 7 of the UI/UX audit).
///
/// The audit found three unrelated button treatments across two screens, and
/// singled out the worst of them: in the popover, `Stop` was a filled accent
/// button sitting beside `Quit`, which made the loudest control on screen the
/// one that ends the session.
///
/// It was worse than it looked. That button also carried
/// `.keyboardShortcut(.defaultAction)`, and its title flips to "Stop" the
/// moment sharing starts — so opening the popover during a session and pressing
/// Return killed the second display. The variant is not decoration here: it
/// decides whether a control may take Return at all, and `destructive` may not.
public enum DSButtonVariant: String, CaseIterable, Sendable {
    /// The one obvious action. Connect, Start.
    case primary
    /// Present but quiet. Rescan, Copy, Open Settings.
    case secondary
    /// Available without asking for attention. Quit, dismiss.
    case ghost
    /// Ends something. Stop, Disconnect.
    case destructive

    /// How loudly the variant asks to be pressed. Ordered, so the rule
    /// "ending a session is never the loudest thing on screen" is checkable
    /// rather than a matter of opinion about two hex values.
    public var prominence: Int {
        switch self {
        case .primary: return 3
        case .secondary: return 2
        case .destructive: return 1
        case .ghost: return 0
        }
    }

    /// Whether Return may activate this variant.
    ///
    /// Always false for `destructive`. See the note above: this is the exact
    /// defect that made the popover dangerous with the keyboard.
    public var canBeDefaultAction: Bool { self != .destructive }

    /// The variant for the popover's Start/Stop control.
    ///
    /// Derived in one tested place rather than written inline in the view,
    /// because the whole failure was that the button's meaning changed with
    /// state while its appearance and its keyboard binding did not.
    public static func forSession(isActive: Bool) -> DSButtonVariant {
        isActive ? .destructive : .primary
    }

    var fill: Color {
        switch self {
        case .primary: return DSColor.accent
        case .secondary: return DSColor.surfaceRaised
        case .ghost, .destructive: return .clear
        }
    }

    var pressedFill: Color {
        switch self {
        case .primary: return DSColor.accentPress
        case .secondary: return DSColor.borderStrong
        case .ghost: return DSColor.text.opacity(0.07)
        case .destructive: return DSColor.error.opacity(0.1)
        }
    }

    var foreground: Color {
        switch self {
        case .primary: return DSColor.accentInk
        case .secondary: return DSColor.text
        case .ghost: return DSColor.textMuted
        case .destructive: return DSColor.error
        }
    }

    var border: Color {
        switch self {
        case .primary, .ghost: return .clear
        case .secondary: return DSColor.borderStrong
        // Outline rather than fill, at 40%: findable without shouting.
        case .destructive: return DSColor.error.opacity(0.4)
        }
    }

    var borderWidth: CGFloat {
        switch self {
        case .primary, .ghost: return 0
        case .secondary, .destructive: return 1
        }
    }
}

public enum DSControlSize: Sendable {
    case standard
    /// The single tallest action on a screen. At most one per view.
    case hero

    public var height: CGFloat {
        switch self {
        case .standard: return 36
        case .hero: return 44
        }
    }
}

/// The focus ring, shared by buttons and fields.
///
/// The audit found no visible focus indicator anywhere in either app. Both
/// interfaces were operable by keyboard and neither showed where the keyboard
/// was, which is the same as not being operable by keyboard.
struct DSFocusRing: View {
    let radius: CGFloat
    let visible: Bool

    static let opacity: Double = 0.6
    static let width: CGFloat = 2
    static let offset: CGFloat = 2

    var body: some View {
        RoundedRectangle(cornerRadius: radius + Self.offset, style: .continuous)
            .strokeBorder(
                DSColor.accent.opacity(Self.opacity),
                lineWidth: visible ? Self.width : 0
            )
            .padding(-Self.offset)
            .opacity(visible ? 1 : 0)
            .animation(DSMotion.ease(), value: visible)
    }
}

public struct DSButtonStyle: ButtonStyle {
    let variant: DSButtonVariant
    let size: DSControlSize
    let focused: Bool

    public func makeBody(configuration: Configuration) -> some View {
        // A nested View rather than reading @Environment on the style itself:
        // property wrappers on a ButtonStyle are not tracked, so a disabled
        // button would keep drawing at full strength.
        Content(configuration: configuration, variant: variant, size: size, focused: focused)
    }

    private struct Content: View {
        let configuration: DSButtonStyle.Configuration
        let variant: DSButtonVariant
        let size: DSControlSize
        let focused: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: DSFont.f3, weight: .semibold))
                .foregroundStyle(variant.foreground)
                .lineLimit(1)
                .padding(.horizontal, DSSpacing.s4 - 2)
                .frame(height: size.height)
                .frame(maxWidth: size == .hero ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                        .fill(configuration.isPressed ? variant.pressedFill : variant.fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                        .strokeBorder(variant.border, lineWidth: variant.borderWidth)
                )
                .overlay(DSFocusRing(radius: DSRadius.md, visible: focused))
                .contentShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                // The audit asks for 40% and a tooltip; the tooltip is the call
                // site's job, since only it knows why.
                .opacity(isEnabled ? 1 : 0.4)
                .offset(y: configuration.isPressed ? 1 : 0)
                .animation(DSMotion.ease(), value: configuration.isPressed)
        }
    }
}

/// A button from the system.
///
/// Owns its own `@FocusState` because a `ButtonStyle` cannot see focus, and the
/// ring has to be drawn by something that can.
public struct DSButton<Label: View>: View {
    private let variant: DSButtonVariant
    private let size: DSControlSize
    private let wantsDefaultAction: Bool
    private let shortcut: KeyEquivalent?
    private let action: () -> Void
    private let label: Label

    @FocusState private var focused: Bool

    public init(
        variant: DSButtonVariant,
        size: DSControlSize = .standard,
        defaultAction: Bool = false,
        shortcut: KeyEquivalent? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.variant = variant
        self.size = size
        self.wantsDefaultAction = defaultAction
        self.shortcut = shortcut
        self.action = action
        self.label = label()
    }

    /// Whether this button actually ends up bound to Return.
    ///
    /// A request for the default action is granted only if the variant allows
    /// it — asking is not enough, so no future call site can rebind Return to
    /// something that ends a session by passing one extra argument.
    var takesReturn: Bool { wantsDefaultAction && variant.canBeDefaultAction }

    /// Resolved here rather than by the call site, so `.keyboardShortcut` is
    /// applied to the Button itself. Attached to the wrapper instead, it lands
    /// on a container and quietly never fires.
    var resolvedShortcut: KeyboardShortcut? {
        if takesReturn { return .defaultAction }
        if let shortcut { return KeyboardShortcut(shortcut) }
        return nil
    }

    public var body: some View {
        Button(action: action) { label }
            .buttonStyle(DSButtonStyle(variant: variant, size: size, focused: focused))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .keyboardShortcut(resolvedShortcut)
    }
}

extension DSButton where Label == Text {
    public init(
        _ title: String,
        variant: DSButtonVariant,
        size: DSControlSize = .standard,
        defaultAction: Bool = false,
        shortcut: KeyEquivalent? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            variant: variant, size: size, defaultAction: defaultAction,
            shortcut: shortcut, action: action
        ) {
            Text(title)
        }
    }
}
