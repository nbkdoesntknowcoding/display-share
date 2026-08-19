//! DOM key codes to Windows virtual-key codes (Task 8.3).
//!
//! The mirror of `KeyMap.swift` on the Mac side. Both map PHYSICAL key codes
//! (`KeyA`, `Digit1`) rather than the characters they produce, so a Mac using a
//! UK layout driving a Windows machine set to US still types what the user
//! pressed — the letter is decided by the receiving machine's own layout.
//!
//! Plain data with no Windows types in it, so it can be tested on any platform.
//! Injection itself lives in `input.rs`.

/// A resolved key: the virtual-key code, and whether it lives in the extended
/// part of the keyboard.
///
/// The extended flag is not decoration. Without `KEYEVENTF_EXTENDEDKEY`, the
/// arrow keys and the navigation cluster share scan codes with the numeric
/// keypad, so Right Arrow arrives as Numpad6 whenever Num Lock happens to be on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Key {
    pub virtual_key: u16,
    pub extended: bool,
}

const fn key(virtual_key: u16) -> Key {
    Key { virtual_key, extended: false }
}

const fn extended(virtual_key: u16) -> Key {
    Key { virtual_key, extended: true }
}

/// Resolves a DOM `KeyboardEvent.code` to a Windows key.
///
/// Returns `None` for codes with no Windows equivalent, which are dropped
/// rather than guessed at: injecting the wrong key is worse than injecting none.
pub fn lookup(code: &str) -> Option<Key> {
    // Letters and digits are contiguous in both spaces, so they are computed
    // rather than listed — 36 more match arms would be 36 more chances to typo.
    if let Some(letter) = code.strip_prefix("Key") {
        let bytes = letter.as_bytes();
        if bytes.len() == 1 && bytes[0].is_ascii_uppercase() {
            return Some(key(bytes[0] as u16));
        }
    }
    if let Some(digit) = code.strip_prefix("Digit") {
        let bytes = digit.as_bytes();
        if bytes.len() == 1 && bytes[0].is_ascii_digit() {
            return Some(key(bytes[0] as u16));
        }
    }
    if let Some(number) = code.strip_prefix('F') {
        if let Ok(n) = number.parse::<u16>() {
            // VK_F1 = 0x70 through VK_F24.
            if (1..=24).contains(&n) {
                return Some(key(0x70 + n - 1));
            }
        }
    }
    if let Some(digit) = code.strip_prefix("Numpad") {
        let bytes = digit.as_bytes();
        if bytes.len() == 1 && bytes[0].is_ascii_digit() {
            return Some(key(0x60 + (bytes[0] - b'0') as u16));
        }
    }

    Some(match code {
        // Editing and whitespace
        "Escape" => key(0x1B),
        "Tab" => key(0x09),
        "CapsLock" => key(0x14),
        "Space" => key(0x20),
        "Backspace" => key(0x08),
        "Enter" => key(0x0D),

        // Modifiers. Left and right are distinct virtual keys, and the right
        // ones are extended.
        "ShiftLeft" => key(0xA0),
        "ShiftRight" => key(0xA1),
        "ControlLeft" => key(0xA2),
        "ControlRight" => extended(0xA3),
        "AltLeft" => key(0xA4),
        "AltRight" => extended(0xA5),
        // The Mac's Command key. Mapped to Windows rather than dropped, so
        // Command-Tab style muscle memory reaches something sensible.
        "MetaLeft" => extended(0x5B),
        "MetaRight" => extended(0x5C),

        // Arrows and navigation — all extended, see the note on Key.
        "ArrowLeft" => extended(0x25),
        "ArrowUp" => extended(0x26),
        "ArrowRight" => extended(0x27),
        "ArrowDown" => extended(0x28),
        "Insert" => extended(0x2D),
        "Delete" => extended(0x2E),
        "Home" => extended(0x24),
        "End" => extended(0x23),
        "PageUp" => extended(0x21),
        "PageDown" => extended(0x22),

        // Punctuation. The OEM codes are positional: VK_OEM_1 is wherever the
        // semicolon sits on a US keyboard, whatever it prints elsewhere.
        "Semicolon" => key(0xBA),
        "Equal" => key(0xBB),
        "Comma" => key(0xBC),
        "Minus" => key(0xBD),
        "Period" => key(0xBE),
        "Slash" => key(0xBF),
        "Backquote" => key(0xC0),
        "BracketLeft" => key(0xDB),
        "Backslash" => key(0xDC),
        "BracketRight" => key(0xDD),
        "Quote" => key(0xDE),
        "IntlBackslash" => key(0xE2),

        // Numeric keypad
        "NumpadMultiply" => key(0x6A),
        "NumpadAdd" => key(0x6B),
        "NumpadSubtract" => key(0x6D),
        "NumpadDecimal" => key(0x6E),
        "NumpadDivide" => extended(0x6F),
        "NumpadEnter" => extended(0x0D),
        "NumLock" => extended(0x90),

        // Locks and system keys
        "ScrollLock" => key(0x91),
        "PrintScreen" => extended(0x2C),
        "Pause" => key(0x13),
        "ContextMenu" => extended(0x5D),

        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_and_digits_map_to_their_ascii_codes() {
        assert_eq!(lookup("KeyA").unwrap().virtual_key, 0x41);
        assert_eq!(lookup("KeyZ").unwrap().virtual_key, 0x5A);
        assert_eq!(lookup("Digit0").unwrap().virtual_key, 0x30);
        assert_eq!(lookup("Digit9").unwrap().virtual_key, 0x39);
    }

    #[test]
    fn function_keys_are_sequential_from_f1() {
        assert_eq!(lookup("F1").unwrap().virtual_key, 0x70);
        assert_eq!(lookup("F12").unwrap().virtual_key, 0x7B);
        // F13+ exists on Mac keyboards and is valid on Windows too.
        assert_eq!(lookup("F24").unwrap().virtual_key, 0x87);
        assert!(lookup("F25").is_none(), "there is no VK_F25");
    }

    #[test]
    fn arrows_and_navigation_are_extended() {
        // Without the extended flag these collide with the numeric keypad, so
        // Right Arrow types 6 whenever Num Lock is on.
        for code in ["ArrowLeft", "ArrowUp", "ArrowRight", "ArrowDown", "Home", "End",
                     "PageUp", "PageDown", "Insert", "Delete"] {
            assert!(lookup(code).unwrap().extended, "{code} must be extended");
        }
    }

    #[test]
    fn left_modifiers_are_not_extended_but_right_ones_are() {
        assert!(!lookup("ControlLeft").unwrap().extended);
        assert!(lookup("ControlRight").unwrap().extended);
        assert!(!lookup("AltLeft").unwrap().extended);
        assert!(lookup("AltRight").unwrap().extended);
        // Shift is the exception: neither side is extended.
        assert!(!lookup("ShiftLeft").unwrap().extended);
        assert!(!lookup("ShiftRight").unwrap().extended);
    }

    #[test]
    fn numpad_digits_are_distinct_from_the_number_row() {
        assert_eq!(lookup("Numpad0").unwrap().virtual_key, 0x60);
        assert_eq!(lookup("Numpad9").unwrap().virtual_key, 0x69);
        assert_ne!(
            lookup("Numpad1").unwrap().virtual_key,
            lookup("Digit1").unwrap().virtual_key
        );
    }

    #[test]
    fn numpad_enter_shares_a_virtual_key_with_return_but_is_extended() {
        let enter = lookup("Enter").unwrap();
        let numpad = lookup("NumpadEnter").unwrap();
        assert_eq!(enter.virtual_key, numpad.virtual_key);
        assert!(!enter.extended && numpad.extended);
    }

    #[test]
    fn unknown_codes_are_dropped_rather_than_guessed() {
        // Injecting the wrong key is worse than injecting none.
        assert!(lookup("").is_none());
        assert!(lookup("Fn").is_none());
        assert!(lookup("KeyAB").is_none());
        assert!(lookup("Keya").is_none(), "codes are case sensitive");
        assert!(lookup("Digit10").is_none());
        assert!(lookup("LaunchMail").is_none());
    }

    #[test]
    fn every_key_the_mac_capture_can_send_resolves() {
        // The receiver-side capture emits these; an unmapped one is silently
        // dead in the user's hands.
        for code in [
            "KeyA", "KeyQ", "Digit1", "Space", "Enter", "Backspace", "Tab", "Escape",
            "ShiftLeft", "ControlLeft", "AltLeft", "MetaLeft", "ArrowUp", "Delete",
            "Semicolon", "Slash", "Backquote", "BracketLeft", "Quote", "Minus", "Equal",
            "Period", "Comma", "Backslash", "F1", "F12", "CapsLock",
        ] {
            assert!(lookup(code).is_some(), "{code} does not map");
        }
    }
}
