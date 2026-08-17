import Carbon.HIToolbox
import CoreGraphics
import XCTest

@testable import DisplayShareCore

/// Task 5.2. Keycode and coordinate mapping are pure, so they are tested
/// directly — unlike CGEvent posting, which needs Accessibility permission.
final class KeyMapTests: XCTestCase {

    func testLettersMapToCarbonKeycodes() {
        XCTAssertEqual(KeyMap.keyCode(for: "KeyA"), CGKeyCode(kVK_ANSI_A))
        XCTAssertEqual(KeyMap.keyCode(for: "KeyZ"), CGKeyCode(kVK_ANSI_Z))
    }

    func testEveryLetterAndDigitIsMapped() {
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            let code = "Key\(Character(UnicodeScalar(scalar)!))"
            XCTAssertNotNil(KeyMap.keyCode(for: code), "\(code) is unmapped")
        }
        for digit in 0...9 {
            XCTAssertNotNil(KeyMap.keyCode(for: "Digit\(digit)"), "Digit\(digit) is unmapped")
        }
    }

    /// The keys people actually use for editing. A gap here means a dead key on
    /// the receiver with no visible error.
    func testEditingAndNavigationKeysAreMapped() {
        let essential = [
            "Enter", "Tab", "Space", "Backspace", "Delete", "Escape",
            "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
            "Home", "End", "PageUp", "PageDown",
        ]
        for code in essential {
            XCTAssertNotNil(KeyMap.keyCode(for: code), "\(code) is unmapped")
        }
    }

    /// Backspace is `kVK_Delete` on macOS and Delete is `kVK_ForwardDelete` —
    /// an easy and very visible thing to get backwards.
    func testBackspaceAndDeleteAreNotSwapped() {
        XCTAssertEqual(KeyMap.keyCode(for: "Backspace"), CGKeyCode(kVK_Delete))
        XCTAssertEqual(KeyMap.keyCode(for: "Delete"), CGKeyCode(kVK_ForwardDelete))
        XCTAssertNotEqual(KeyMap.keyCode(for: "Backspace"), KeyMap.keyCode(for: "Delete"))
    }

    /// Left and right modifiers are distinct physical keys; collapsing them
    /// breaks shortcuts that care which side was pressed.
    func testLeftAndRightModifiersAreDistinct() {
        XCTAssertNotEqual(KeyMap.keyCode(for: "ShiftLeft"), KeyMap.keyCode(for: "ShiftRight"))
        XCTAssertNotEqual(KeyMap.keyCode(for: "MetaLeft"), KeyMap.keyCode(for: "MetaRight"))
        XCTAssertEqual(KeyMap.keyCode(for: "MetaLeft"), CGKeyCode(kVK_Command))
    }

    func testUnknownCodeReturnsNilRatherThanAWrongKey() {
        XCTAssertNil(KeyMap.keyCode(for: "Fn"))
        XCTAssertNil(KeyMap.keyCode(for: "MediaPlayPause"))
        XCTAssertNil(KeyMap.keyCode(for: ""))
    }

    func testNoTwoCodesShareAKeycode() {
        var seen: [CGKeyCode: String] = [:]
        for (code, keyCode) in KeyMap.table {
            if let existing = seen[keyCode] {
                XCTFail("\(code) and \(existing) both map to \(keyCode)")
            }
            seen[keyCode] = code
        }
    }

    func testModifierFlags() {
        XCTAssertEqual(KeyMap.flags(shift: false, ctrl: false, alt: false, meta: false), [])
        XCTAssertEqual(KeyMap.flags(shift: true, ctrl: false, alt: false, meta: false), .maskShift)
        XCTAssertEqual(KeyMap.flags(shift: false, ctrl: false, alt: false, meta: true), .maskCommand)

        let all = KeyMap.flags(shift: true, ctrl: true, alt: true, meta: true)
        XCTAssertTrue(all.contains(.maskShift))
        XCTAssertTrue(all.contains(.maskControl))
        XCTAssertTrue(all.contains(.maskAlternate))
        XCTAssertTrue(all.contains(.maskCommand))
    }
}

/// Coordinate mapping: normalised video coords -> global display coords.
/// Getting the display's origin offset wrong is the classic failure — clicks
/// land on the primary display instead of the virtual one.
final class InputCoordinateTests: XCTestCase {

    /// Mirrors InputInjector.globalPoint so the arithmetic is asserted directly.
    private func globalPoint(x: Double, y: Double, bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.origin.x + x * bounds.width, y: bounds.origin.y + y * bounds.height)
    }

    func testCentreMapsToDisplayCentre() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(globalPoint(x: 0.5, y: 0.5, bounds: bounds), CGPoint(x: 960, y: 540))
    }

    func testCornersMapToDisplayCorners() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(globalPoint(x: 0, y: 0, bounds: bounds), CGPoint(x: 0, y: 0))
        XCTAssertEqual(globalPoint(x: 1, y: 1, bounds: bounds), CGPoint(x: 1920, y: 1080))
    }

    /// The virtual display usually sits at a NEGATIVE x offset (to the left of
    /// the main display). If the origin is ignored, every click lands on the
    /// wrong screen — which is the bug this test exists to prevent.
    func testNegativeOriginIsRespected() {
        let bounds = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(globalPoint(x: 0, y: 0, bounds: bounds), CGPoint(x: -1920, y: 0))
        XCTAssertEqual(globalPoint(x: 0.5, y: 0.5, bounds: bounds), CGPoint(x: -960, y: 540))
        XCTAssertEqual(globalPoint(x: 1, y: 1, bounds: bounds), CGPoint(x: 0, y: 1080))
    }

    func testNonSquareAspectMapsIndependentlyPerAxis() {
        // 1920x810, the 21:9 geometry from Task 3.3's negotiation.
        let bounds = CGRect(x: -1920, y: 0, width: 1920, height: 810)
        XCTAssertEqual(globalPoint(x: 0.25, y: 0.5, bounds: bounds), CGPoint(x: -1440, y: 405))
    }
}
