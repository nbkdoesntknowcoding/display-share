import Carbon.HIToolbox
import Foundation

/// Maps DOM `KeyboardEvent.code` values to macOS virtual keycodes.
///
/// `code` is a PHYSICAL key identifier, and macOS virtual keycodes are also
/// physical positions, so this is a position-to-position table and needs no
/// knowledge of either side's keyboard layout. Mapping the *character* instead
/// would break the moment the two machines disagree on layout.
///
/// Values come from Carbon's `kVK_*` constants rather than being hardcoded.
enum KeyMap {

    static let table: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            // Letters
            "KeyA": CGKeyCode(kVK_ANSI_A), "KeyB": CGKeyCode(kVK_ANSI_B),
            "KeyC": CGKeyCode(kVK_ANSI_C), "KeyD": CGKeyCode(kVK_ANSI_D),
            "KeyE": CGKeyCode(kVK_ANSI_E), "KeyF": CGKeyCode(kVK_ANSI_F),
            "KeyG": CGKeyCode(kVK_ANSI_G), "KeyH": CGKeyCode(kVK_ANSI_H),
            "KeyI": CGKeyCode(kVK_ANSI_I), "KeyJ": CGKeyCode(kVK_ANSI_J),
            "KeyK": CGKeyCode(kVK_ANSI_K), "KeyL": CGKeyCode(kVK_ANSI_L),
            "KeyM": CGKeyCode(kVK_ANSI_M), "KeyN": CGKeyCode(kVK_ANSI_N),
            "KeyO": CGKeyCode(kVK_ANSI_O), "KeyP": CGKeyCode(kVK_ANSI_P),
            "KeyQ": CGKeyCode(kVK_ANSI_Q), "KeyR": CGKeyCode(kVK_ANSI_R),
            "KeyS": CGKeyCode(kVK_ANSI_S), "KeyT": CGKeyCode(kVK_ANSI_T),
            "KeyU": CGKeyCode(kVK_ANSI_U), "KeyV": CGKeyCode(kVK_ANSI_V),
            "KeyW": CGKeyCode(kVK_ANSI_W), "KeyX": CGKeyCode(kVK_ANSI_X),
            "KeyY": CGKeyCode(kVK_ANSI_Y), "KeyZ": CGKeyCode(kVK_ANSI_Z),

            // Digit row
            "Digit0": CGKeyCode(kVK_ANSI_0), "Digit1": CGKeyCode(kVK_ANSI_1),
            "Digit2": CGKeyCode(kVK_ANSI_2), "Digit3": CGKeyCode(kVK_ANSI_3),
            "Digit4": CGKeyCode(kVK_ANSI_4), "Digit5": CGKeyCode(kVK_ANSI_5),
            "Digit6": CGKeyCode(kVK_ANSI_6), "Digit7": CGKeyCode(kVK_ANSI_7),
            "Digit8": CGKeyCode(kVK_ANSI_8), "Digit9": CGKeyCode(kVK_ANSI_9),

            // Punctuation
            "Minus": CGKeyCode(kVK_ANSI_Minus), "Equal": CGKeyCode(kVK_ANSI_Equal),
            "BracketLeft": CGKeyCode(kVK_ANSI_LeftBracket),
            "BracketRight": CGKeyCode(kVK_ANSI_RightBracket),
            "Backslash": CGKeyCode(kVK_ANSI_Backslash),
            "Semicolon": CGKeyCode(kVK_ANSI_Semicolon),
            "Quote": CGKeyCode(kVK_ANSI_Quote), "Backquote": CGKeyCode(kVK_ANSI_Grave),
            "Comma": CGKeyCode(kVK_ANSI_Comma), "Period": CGKeyCode(kVK_ANSI_Period),
            "Slash": CGKeyCode(kVK_ANSI_Slash),

            // Editing and navigation
            "Enter": CGKeyCode(kVK_Return), "NumpadEnter": CGKeyCode(kVK_ANSI_KeypadEnter),
            "Tab": CGKeyCode(kVK_Tab), "Space": CGKeyCode(kVK_Space),
            "Backspace": CGKeyCode(kVK_Delete), "Delete": CGKeyCode(kVK_ForwardDelete),
            "Escape": CGKeyCode(kVK_Escape),
            "Home": CGKeyCode(kVK_Home), "End": CGKeyCode(kVK_End),
            "PageUp": CGKeyCode(kVK_PageUp), "PageDown": CGKeyCode(kVK_PageDown),
            "ArrowUp": CGKeyCode(kVK_UpArrow), "ArrowDown": CGKeyCode(kVK_DownArrow),
            "ArrowLeft": CGKeyCode(kVK_LeftArrow), "ArrowRight": CGKeyCode(kVK_RightArrow),

            // Modifiers. Left/right are distinct physical keys and map separately.
            "ShiftLeft": CGKeyCode(kVK_Shift), "ShiftRight": CGKeyCode(kVK_RightShift),
            "ControlLeft": CGKeyCode(kVK_Control), "ControlRight": CGKeyCode(kVK_RightControl),
            "AltLeft": CGKeyCode(kVK_Option), "AltRight": CGKeyCode(kVK_RightOption),
            "MetaLeft": CGKeyCode(kVK_Command), "MetaRight": CGKeyCode(kVK_RightCommand),
            "CapsLock": CGKeyCode(kVK_CapsLock),

            // Function row
            "F1": CGKeyCode(kVK_F1), "F2": CGKeyCode(kVK_F2), "F3": CGKeyCode(kVK_F3),
            "F4": CGKeyCode(kVK_F4), "F5": CGKeyCode(kVK_F5), "F6": CGKeyCode(kVK_F6),
            "F7": CGKeyCode(kVK_F7), "F8": CGKeyCode(kVK_F8), "F9": CGKeyCode(kVK_F9),
            "F10": CGKeyCode(kVK_F10), "F11": CGKeyCode(kVK_F11), "F12": CGKeyCode(kVK_F12),
        ]

        // Numpad
        let numpad: [(String, Int)] = [
            ("Numpad0", kVK_ANSI_Keypad0), ("Numpad1", kVK_ANSI_Keypad1),
            ("Numpad2", kVK_ANSI_Keypad2), ("Numpad3", kVK_ANSI_Keypad3),
            ("Numpad4", kVK_ANSI_Keypad4), ("Numpad5", kVK_ANSI_Keypad5),
            ("Numpad6", kVK_ANSI_Keypad6), ("Numpad7", kVK_ANSI_Keypad7),
            ("Numpad8", kVK_ANSI_Keypad8), ("Numpad9", kVK_ANSI_Keypad9),
            ("NumpadAdd", kVK_ANSI_KeypadPlus), ("NumpadSubtract", kVK_ANSI_KeypadMinus),
            ("NumpadMultiply", kVK_ANSI_KeypadMultiply),
            ("NumpadDivide", kVK_ANSI_KeypadDivide),
            ("NumpadDecimal", kVK_ANSI_KeypadDecimal),
        ]
        for (code, key) in numpad { map[code] = CGKeyCode(key) }
        return map
    }()

    static func keyCode(for domCode: String) -> CGKeyCode? {
        table[domCode]
    }

    /// Modifier keys must also contribute to the event's CGEventFlags, or a
    /// Cmd+A posted as two independent key events will not register as a chord.
    static func flags(shift: Bool, ctrl: Bool, alt: Bool, meta: Bool) -> CGEventFlags {
        var flags: CGEventFlags = []
        if shift { flags.insert(.maskShift) }
        if ctrl { flags.insert(.maskControl) }
        if alt { flags.insert(.maskAlternate) }
        if meta { flags.insert(.maskCommand) }
        return flags
    }
}
