import AppKit
import CoreGraphics
import Foundation

/// Turns forwarded input into real CGEvents on the virtual display.
///
/// Coordinate mapping is the crux. Events arrive normalised 0-1 within the
/// receiver's video rect (SPEC §4.10), and CGEvent wants **global** display
/// coordinates — top-left origin, spanning all displays. So a point is mapped
/// through the virtual display's `CGDisplayBounds`, which already sits at the
/// right offset in the global space. That keeps the mapping correct no matter
/// where macOS has arranged the virtual display relative to the real one.
///
/// Requires **Accessibility** permission. Without it macOS silently swallows
/// posted events: nothing errors, nothing moves. So permission is checked up
/// front and surfaced, rather than leaving the user with a dead cursor.
public final class InputInjector: @unchecked Sendable {

    public struct Statistics: Sendable, Equatable {
        public var injected = 0
        public var skippedNoPermission = 0
        public var skippedUnmappedKey = 0
        public var lastUnmappedCode: String?
    }

    private let lock = NSLock()
    private var stats = Statistics()
    private var displayID: CGDirectDisplayID = 0
    /// Modifier state, tracked so a chord posts with the right flags.
    private var activeFlags: CGEventFlags = []
    /// Buttons currently held, so a drag produces `.leftMouseDragged` rather
    /// than plain moves — many apps ignore a drag expressed as movement.
    private var heldButtons = Set<Int>()

    public init() {}

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    public func setDisplay(_ id: CGDirectDisplayID) {
        lock.lock()
        displayID = id
        lock.unlock()
    }

    // MARK: - Permission

    /// Whether this process may post synthetic events.
    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Raises the system prompt the first time; afterwards the user must toggle
    /// it in System Settings.
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        // kAXTrustedCheckOptionPrompt is a global the compiler cannot prove is
        // immutable; its literal value is stable API.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Injection

    public func handle(_ event: ForwardedInputEvent) {
        guard Self.hasAccessibilityPermission else {
            lock.lock(); stats.skippedNoPermission += 1; lock.unlock()
            return
        }
        lock.lock()
        let display = displayID
        lock.unlock()
        guard display != 0 else { return }

        switch event.k {
        case .move:
            guard let x = event.x, let y = event.y else { return }
            moveCursor(to: x, y: y, on: display)
        case .down:
            press(button: event.b ?? 0, down: true, on: display)
        case .up:
            press(button: event.b ?? 0, down: false, on: display)
        case .scroll:
            scroll(dx: event.dx ?? 0, dy: event.dy ?? 0)
        case .key:
            guard let code = event.code, let down = event.down else { return }
            key(code: code, down: down, mods: event.mods)
        }
    }

    /// Normalised video coordinates -> global display coordinates.
    private func globalPoint(x: Double, y: Double, on display: CGDirectDisplayID) -> CGPoint {
        let bounds = CGDisplayBounds(display)
        return CGPoint(
            x: bounds.origin.x + x * bounds.width,
            y: bounds.origin.y + y * bounds.height)
    }

    private func moveCursor(to x: Double, y: Double, on display: CGDirectDisplayID) {
        let point = globalPoint(x: x, y: y, on: display)

        lock.lock()
        let dragging = heldButtons.first
        let flags = activeFlags
        lock.unlock()

        // A held button means this is a DRAG. Posting a plain move instead
        // breaks text selection and window dragging in most apps.
        let type: CGEventType
        let button: CGMouseButton
        switch dragging {
        case 0: type = .leftMouseDragged; button = .left
        case 1: type = .otherMouseDragged; button = .center
        case 2: type = .rightMouseDragged; button = .right
        default: type = .mouseMoved; button = .left
        }

        if let event = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        {
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        // Warp as well: the posted event moves the pointer for applications, but
        // CGWarpMouseCursorPosition is what reliably relocates the drawn cursor
        // when it is currently on another display.
        CGWarpMouseCursorPosition(point)

        lock.lock(); stats.injected += 1; lock.unlock()
    }

    private func press(button: Int, down: Bool, on display: CGDirectDisplayID) {
        lock.lock()
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        let flags = activeFlags
        lock.unlock()

        let location = CGEvent(source: nil)?.location ?? .zero
        let mouseButton: CGMouseButton
        let type: CGEventType
        switch button {
        case 1:
            mouseButton = .center
            type = down ? .otherMouseDown : .otherMouseUp
        case 2:
            mouseButton = .right
            type = down ? .rightMouseDown : .rightMouseUp
        default:
            mouseButton = .left
            type = down ? .leftMouseDown : .leftMouseUp
        }

        if let event = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
            mouseButton: mouseButton)
        {
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        lock.lock(); stats.injected += 1; lock.unlock()
    }

    private func scroll(dx: Double, dy: Double) {
        // Line units: pixel-unit scrolling ignores the user's scroll settings.
        if let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
            wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
        {
            lock.lock(); let flags = activeFlags; lock.unlock()
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        lock.lock(); stats.injected += 1; lock.unlock()
    }

    private func key(code: String, down: Bool, mods: ForwardedInputEvent.Modifiers?) {
        guard let keyCode = KeyMap.keyCode(for: code) else {
            lock.lock()
            stats.skippedUnmappedKey += 1
            stats.lastUnmappedCode = code
            lock.unlock()
            return
        }

        // Track the receiver's modifier state: a chord like Cmd+A only registers
        // if the flags are attached to the key event itself.
        let flags = KeyMap.flags(
            shift: mods?.shift ?? false, ctrl: mods?.ctrl ?? false,
            alt: mods?.alt ?? false, meta: mods?.meta ?? false)
        lock.lock()
        activeFlags = flags
        lock.unlock()

        if let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) {
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        lock.lock(); stats.injected += 1; lock.unlock()
    }

    /// Releases everything held. Called when forwarding stops or the receiver
    /// disconnects, so nothing is left stuck down on the Mac.
    public func releaseAll() {
        lock.lock()
        let buttons = heldButtons
        heldButtons.removeAll()
        activeFlags = []
        lock.unlock()

        guard Self.hasAccessibilityPermission else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        for button in buttons {
            let type: CGEventType = button == 2 ? .rightMouseUp : (button == 1 ? .otherMouseUp : .leftMouseUp)
            let mouseButton: CGMouseButton = button == 2 ? .right : (button == 1 ? .center : .left)
            CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
                mouseButton: mouseButton)?.post(tap: .cghidEventTap)
        }
    }
}
