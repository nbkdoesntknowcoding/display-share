import SwiftUI
import XCTest

@testable import DisplayShareCore

/// The button system's rules (Command 7 of the UI/UX audit).
///
/// These are not appearance tests. Each one guards a rule that a defect in this
/// project already broke: a session-ending control drawn as the loudest thing on
/// screen, and that same control silently bound to Return.
final class DSButtonTests: XCTestCase {

    // MARK: - Prominence

    /// The audit's central complaint about the popover, as an assertion.
    func testDestructiveIsNeverTheLoudestVariant() {
        XCTAssertLessThan(
            DSButtonVariant.destructive.prominence,
            DSButtonVariant.primary.prominence,
            "Stop must not outrank the primary action — it was a filled accent button"
        )
        XCTAssertLessThan(
            DSButtonVariant.destructive.prominence,
            DSButtonVariant.secondary.prominence
        )
    }

    func testPrimaryIsTheLoudest() {
        let loudest = DSButtonVariant.allCases.max { $0.prominence < $1.prominence }
        XCTAssertEqual(loudest, .primary)
    }

    func testEveryVariantHasADistinctProminence() {
        let levels = DSButtonVariant.allCases.map(\.prominence)
        XCTAssertEqual(Set(levels).count, DSButtonVariant.allCases.count)
    }

    // MARK: - Return

    func testDestructiveCannotTakeTheDefaultAction() {
        XCTAssertFalse(DSButtonVariant.destructive.canBeDefaultAction)
    }

    func testEveryOtherVariantCanTakeTheDefaultAction() {
        for variant in DSButtonVariant.allCases where variant != .destructive {
            XCTAssertTrue(variant.canBeDefaultAction, "\(variant.rawValue) should accept Return")
        }
    }

    /// Asking for the default action is not the same as getting it.
    ///
    /// The popover's Start/Stop button asks for it unconditionally, exactly as
    /// the old code did — and must be refused it the moment the session is
    /// live, because that is when the label reads "Stop".
    func testRequestingTheDefaultActionIsRefusedWhileASessionIsLive() {
        let start = DSButton(
            "Start", variant: .forSession(isActive: false), defaultAction: true, action: {})
        XCTAssertTrue(start.takesReturn, "Return should start a session")
        XCTAssertNotNil(start.resolvedShortcut)

        let stop = DSButton(
            "Stop", variant: .forSession(isActive: true), defaultAction: true, action: {})
        XCTAssertFalse(stop.takesReturn, "Return must never end a running session")
        XCTAssertNil(stop.resolvedShortcut)
    }

    func testAnExplicitShortcutSurvivesWhenReturnIsRefused() {
        let quit = DSButton("Quit", variant: .ghost, shortcut: "q", action: {})
        XCTAssertFalse(quit.takesReturn)
        XCTAssertEqual(quit.resolvedShortcut, KeyboardShortcut("q"))
    }

    // MARK: - The session mapping

    func testSessionVariantFollowsTheSessionAndNotTheLabel() {
        XCTAssertEqual(DSButtonVariant.forSession(isActive: false), .primary)
        XCTAssertEqual(DSButtonVariant.forSession(isActive: true), .destructive)
    }

    // MARK: - Geometry

    func testHeightsMatchTheSpecifiedScale() {
        XCTAssertEqual(DSControlSize.standard.height, 36)
        XCTAssertEqual(DSControlSize.hero.height, 44)
    }

    /// Geometry comes from the shared token source, not from numbers typed into
    /// a view — the whole point of Command 1.
    func testCornerRadiusComesFromTheTokens() {
        XCTAssertEqual(DSRadius.md, 10)
        XCTAssertEqual(DSRadius.sm, 6)
    }

    func testFocusRingMatchesTheSpecifiedRing() {
        XCTAssertEqual(DSFocusRing.width, 2)
        XCTAssertEqual(DSFocusRing.offset, 2)
        XCTAssertEqual(DSFocusRing.opacity, 0.6)
    }

    // MARK: - Fills

    /// Destructive is an outline. A filled red button is louder than the accent
    /// one it sits beside, which would reintroduce the original defect in a new
    /// colour.
    func testDestructiveIsAnOutlineRatherThanAFill() {
        XCTAssertEqual(DSButtonVariant.destructive.fill, Color.clear)
        XCTAssertEqual(DSButtonVariant.ghost.fill, Color.clear)
        XCTAssertNotEqual(DSButtonVariant.destructive.border, Color.clear)
        XCTAssertEqual(DSButtonVariant.destructive.borderWidth, 1)
    }

    func testOnlyPrimaryUsesTheAccentFill() {
        for variant in DSButtonVariant.allCases {
            if variant == .primary {
                XCTAssertEqual(variant.fill, DSColor.accent)
            } else {
                XCTAssertNotEqual(variant.fill, DSColor.accent)
            }
        }
    }

    // MARK: - Motion

    /// Both apps decelerate on one curve for one duration. They previously did
    /// not: the receiver had its own bezier and the Mac an ad-hoc easeOut.
    func testMotionMatchesTheReceiver() {
        XCTAssertEqual(DSMotion.fast, 0.14, accuracy: 0.0001)
        XCTAssertEqual(DSMotion.base, 0.2, accuracy: 0.0001)
    }
}
