import AppKit
import DisplayShareCore
import Foundation

/// Capturing the Mac's mouse and keyboard for a Windows machine (Task 8.3).
///
/// The mirror of the receiver's `input.ts`, sending the same batched format from
/// SPEC §4.10 so the Windows side needs no second parser.
///
/// Two things here are not obvious and are the reason this is its own file:
///
/// 1. **Coordinates are normalised against the displayed VIDEO rect, not the
///    view.** The layer is letterboxed whenever the window's aspect differs from
///    the stream, so view-relative coordinates would be offset by the bars and
///    land in the wrong place on Windows.
/// 2. **Events are batched.** A moving mouse produces events far faster than the
///    display refreshes, and one WebSocket frame each would compete with video
///    on the same socket.
@MainActor
final class InputForwarder {

    struct Event: Encodable {
        let k: String
        var x: Double?
        var y: Double?
        var b: Int?
        var dx: Double?
        var dy: Double?
        var code: String?
        var down: Bool?
        let t: Int
    }

    private struct Batch: Encodable {
        let type = "input"
        let events: [Event]
    }

    var isEnabled = false {
        didSet {
            if !isEnabled {
                // Drop anything queued: replaying stale motion after re-enabling
                // would jump the cursor.
                pending.removeAll()
                releaseHeldKeys()
            }
            onEnabledChanged?(isEnabled)
        }
    }
    var onEnabledChanged: (@MainActor (Bool) -> Void)?

    private let send: (String) -> Void
    private let origin = Date()
    private var pending: [Event] = []
    private var flushScheduled = false
    private var heldKeys: Set<String> = []

    init(send: @escaping (String) -> Void) {
        self.send = send
    }

    private var stamp: Int { Int(Date().timeIntervalSince(origin) * 1000) }

    func enqueue(force: Bool = false, _ makeEvent: (Int) -> Event) {
        guard isEnabled || force else { return }
        pending.append(makeEvent(stamp))
        guard !flushScheduled else { return }
        flushScheduled = true
        // One flush per frame, matching the receiver's requestAnimationFrame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let batch = Batch(events: pending)
        pending.removeAll()
        guard let data = try? JSONEncoder().encode(batch),
            let text = String(data: data, encoding: .utf8)
        else { return }
        send(text)
    }

    // MARK: - Events

    func move(x: Double, y: Double) {
        enqueue { Event(k: "move", x: x, y: y, t: $0) }
    }

    func button(_ index: Int, down: Bool) {
        enqueue { Event(k: down ? "down" : "up", b: index, t: $0) }
    }

    func scroll(dx: Double, dy: Double) {
        enqueue { Event(k: "scroll", dx: dx, dy: dy, t: $0) }
    }

    func key(code: String, down: Bool) {
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        enqueue { Event(k: "key", code: code, down: down, t: $0) }
    }

    /// Sends key-up for everything still held.
    ///
    /// Called when forwarding stops or the window loses focus. Without it a held
    /// modifier stays down on Windows with no event coming to clear it, and the
    /// machine behaves as though Ctrl were welded on.
    func releaseHeldKeys() {
        guard !heldKeys.isEmpty else { return }
        let held = heldKeys
        heldKeys.removeAll()
        // Forced out even though forwarding has just been switched off: a stuck
        // modifier is worse than one extra message. Toggling isEnabled to do
        // this instead would re-enter the didSet that called us.
        for code in held {
            enqueue(force: true) { Event(k: "key", code: code, down: false, t: $0) }
        }
        flush()
    }
}

/// Maps AppKit key codes to the DOM-style names SPEC §4.10 uses.
///
/// Physical positions, not characters: the Windows side decides what a key
/// prints using its own layout, so a UK Mac driving a US Windows machine types
/// what the user actually pressed.
enum MacKeyCodes {
    static func code(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: return "KeyA"
        case 1: return "KeyS"
        case 2: return "KeyD"
        case 3: return "KeyF"
        case 4: return "KeyH"
        case 5: return "KeyG"
        case 6: return "KeyZ"
        case 7: return "KeyX"
        case 8: return "KeyC"
        case 9: return "KeyV"
        case 11: return "KeyB"
        case 12: return "KeyQ"
        case 13: return "KeyW"
        case 14: return "KeyE"
        case 15: return "KeyR"
        case 16: return "KeyY"
        case 17: return "KeyT"
        case 18: return "Digit1"
        case 19: return "Digit2"
        case 20: return "Digit3"
        case 21: return "Digit4"
        case 22: return "Digit6"
        case 23: return "Digit5"
        case 24: return "Equal"
        case 25: return "Digit9"
        case 26: return "Digit7"
        case 27: return "Minus"
        case 28: return "Digit8"
        case 29: return "Digit0"
        case 30: return "BracketRight"
        case 31: return "KeyO"
        case 32: return "KeyU"
        case 33: return "BracketLeft"
        case 34: return "KeyI"
        case 35: return "KeyP"
        case 36: return "Enter"
        case 37: return "KeyL"
        case 38: return "KeyJ"
        case 39: return "Quote"
        case 40: return "KeyK"
        case 41: return "Semicolon"
        case 42: return "Backslash"
        case 43: return "Comma"
        case 44: return "Slash"
        case 45: return "KeyN"
        case 46: return "KeyM"
        case 47: return "Period"
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "Backquote"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 55: return "MetaLeft"
        case 56: return "ShiftLeft"
        case 57: return "CapsLock"
        case 58: return "AltLeft"
        case 59: return "ControlLeft"
        case 60: return "ShiftRight"
        case 61: return "AltRight"
        case 62: return "ControlRight"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 109: return "F10"
        case 111: return "F12"
        case 114: return "Insert"
        case 115: return "Home"
        case 116: return "PageUp"
        case 117: return "Delete"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "PageDown"
        case 122: return "F1"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        default: return nil
        }
    }

    /// Modifier flags to the DOM codes for the keys that produce them, so a
    /// change in `flagsChanged` can be turned into presses and releases.
    static let modifierCodes: [(NSEvent.ModifierFlags, String)] = [
        (.shift, "ShiftLeft"),
        (.control, "ControlLeft"),
        (.option, "AltLeft"),
        (.command, "MetaLeft"),
        (.capsLock, "CapsLock"),
    ]
}
