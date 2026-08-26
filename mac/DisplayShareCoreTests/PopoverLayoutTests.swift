import XCTest

@testable import DisplayShareCore

/// The popover's structure (Command 9 of the UI/UX audit).
///
/// The audit's finding was that a dead JPEG slider outweighed the connection
/// status, and that dividers appeared or doubled depending on which optional
/// block happened to be visible. Both were properties of a view body, where
/// nothing could check them. The order is now a value, so these are assertions.
final class PopoverLayoutTests: XCTestCase {

    private func ordered(
        isPairing: Bool = false,
        needsScreenRecording: Bool = false,
        needsAccessibility: Bool = false,
        hasUpdate: Bool = false,
        hasBrowserFallback: Bool = false
    ) -> [PopoverSection] {
        PopoverSection.ordered(
            isPairing: isPairing,
            needsScreenRecording: needsScreenRecording,
            needsAccessibility: needsAccessibility,
            hasUpdate: hasUpdate,
            hasBrowserFallback: hasBrowserFallback
        )
    }

    /// Every combination of the five optional inputs. Divider doubling only
    /// showed up in particular combinations — an update notice followed by the
    /// browser fallback — so the invariants below are checked against all 32
    /// rather than the handful anyone would think to open by hand.
    private var everyState: [[PopoverSection]] {
        (0..<32).map { bits in
            ordered(
                isPairing: bits & 1 != 0,
                needsScreenRecording: bits & 2 != 0,
                needsAccessibility: bits & 4 != 0,
                hasUpdate: bits & 8 != 0,
                hasBrowserFallback: bits & 16 != 0
            )
        }
    }

    // MARK: - The reorder

    /// The headline requirement: status leads.
    func testStatusFollowsTheHeaderInEveryState() {
        for sections in everyState {
            XCTAssertEqual(sections.first, .header)
            XCTAssertEqual(sections.dropFirst().first, .status)
        }
    }

    func testStatusOutranksTheDisplaySettingsInEveryState() {
        for sections in everyState {
            let status = sections.firstIndex(of: .status)
            let display = sections.firstIndex(of: .display)
            XCTAssertNotNil(status)
            XCTAssertNotNil(display)
            XCTAssertLessThan(
                status!, display!,
                "settings must not sit above the status line again")
        }
    }

    func testActionsAreAlwaysLast() {
        for sections in everyState {
            XCTAssertEqual(sections.last, .actions)
        }
    }

    /// A PIN is useless after the fact — it has to be visible without scrolling
    /// past the settings to reach it.
    func testAPendingPINSitsAboveTheSettings() {
        let sections = ordered(isPairing: true, hasUpdate: true, hasBrowserFallback: true)
        XCTAssertLessThan(
            sections.firstIndex(of: .pairing)!, sections.firstIndex(of: .display)!)
    }

    // MARK: - Rhythm

    /// With one divider drawn between neighbours, a repeated section would draw
    /// two. The old body attached a divider to each optional block instead,
    /// which is exactly how doubles appeared.
    func testNoSectionAppearsTwice() {
        for sections in everyState {
            XCTAssertEqual(Set(sections).count, sections.count)
        }
    }

    // MARK: - Presence

    func testOptionalSectionsAppearOnlyWhenTheirStateDoes() {
        XCTAssertFalse(ordered().contains(.pairing))
        XCTAssertTrue(ordered(isPairing: true).contains(.pairing))

        XCTAssertFalse(ordered().contains(.update))
        XCTAssertTrue(ordered(hasUpdate: true).contains(.update))

        XCTAssertFalse(ordered().contains(.browserFallback))
        XCTAssertTrue(ordered(hasBrowserFallback: true).contains(.browserFallback))

        XCTAssertFalse(ordered().contains(.screenRecordingNotice))
        XCTAssertTrue(ordered(needsScreenRecording: true).contains(.screenRecordingNotice))
    }

    /// The minimum popover is still a complete one.
    func testTheQuietStateStillHasEverythingThatMatters() {
        XCTAssertEqual(ordered(), [.header, .status, .display, .otherDirection, .actions])
    }

    /// The slider was deleted, not hidden — the JPEG encoder runs only under a
    /// developer command-line flag, so it adjusted a number nothing read. If a
    /// quality section ever reappears, this is where the argument gets made
    /// again.
    func testThereIsNoQualitySection() {
        let names = PopoverSection.allCases.map(\.rawValue)
        XCTAssertFalse(names.contains { $0.lowercased().contains("quality") })
        XCTAssertFalse(names.contains { $0.lowercased().contains("jpeg") })
    }

    // MARK: - Metrics

    /// Spacing comes from the token scale rather than numbers typed into a view.
    func testRhythmComesFromTheTokenScale() {
        XCTAssertEqual(DSPopoverMetrics.padding, DSSpacing.s4)
        XCTAssertEqual(DSPopoverMetrics.dividerMargin, DSSpacing.s3)
        XCTAssertEqual(DSPopoverMetrics.padding, 16)
        XCTAssertEqual(DSPopoverMetrics.dividerMargin, 12)
    }

    // MARK: - Protected content (Phase 5)

    /// Present only when there is a display to release or one to bring back.
    ///
    /// This section exists to explain the one thing the app cannot fix. Shown
    /// permanently it would be a standing apology, at the bottom of every idle
    /// popover, for a problem most sessions never meet.
    func testTheProtectedContentSectionAppearsOnlyWhenItCanDoSomething() {
        let idle = PopoverSection.ordered(
            isPairing: false, needsScreenRecording: false, needsAccessibility: false,
            hasUpdate: false, hasBrowserFallback: false, canReleaseDisplay: false)
        XCTAssertFalse(
            idle.contains(.protectedContent),
            "nothing to release and nothing to restore: \(idle)")

        let sharing = PopoverSection.ordered(
            isPairing: false, needsScreenRecording: false, needsAccessibility: false,
            hasUpdate: false, hasBrowserFallback: false, canReleaseDisplay: true)
        XCTAssertTrue(sharing.contains(.protectedContent))
    }

    /// Above the actions, so releasing the screen is never mistaken for the
    /// control that ends the session — they do different things and one of them
    /// is reversible in a click.
    func testTheProtectedContentSectionSitsAboveTheActions() {
        let sections = PopoverSection.ordered(
            isPairing: false, needsScreenRecording: false, needsAccessibility: false,
            hasUpdate: false, hasBrowserFallback: false, canReleaseDisplay: true)
        guard let explainer = sections.firstIndex(of: .protectedContent),
            let actions = sections.firstIndex(of: .actions)
        else {
            return XCTFail("expected both sections: \(sections)")
        }
        XCTAssertLessThan(explainer, actions)
        XCTAssertEqual(sections.last, .actions, "the actions must still be last")
    }

    /// The urgent things stay urgent. A PIN on screen is the most important
    /// thing in the popover and must not be pushed down by an explainer.
    func testAPendingPINStillOutranksTheExplainer() {
        let sections = PopoverSection.ordered(
            isPairing: true, needsScreenRecording: false, needsAccessibility: false,
            hasUpdate: false, hasBrowserFallback: false, canReleaseDisplay: true)
        XCTAssertLessThan(
            sections.firstIndex(of: .pairing)!, sections.firstIndex(of: .protectedContent)!)
    }
}
