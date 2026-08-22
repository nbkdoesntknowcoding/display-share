import XCTest

@testable import DisplayShareCore

/// Task 4.3. The controller is pure, so congestion behaviour is tested by
/// feeding it sequences rather than by trying to congest a real network.
final class AdaptiveBitrateTests: XCTestCase {

    private var t0 = Date(timeIntervalSince1970: 1_000_000)

    private func sample(
        backlog: Double,
        drop: Double = 0,
        shed: Double = 0,
        queue: Int = 0,
        offset: TimeInterval
    ) -> AdaptiveBitrateController.Sample {
        .init(
            signal: CongestionSignal(
                backlogMillis: backlog, shedRate: shed, decodeQueueDepth: queue,
                receiverDropRate: drop),
            at: t0.addingTimeInterval(offset))
    }

    func testHoldsSteadyOnAHealthyLink() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        let start = controller.currentBitrate
        // Clean but not yet enough consecutive samples to probe upward.
        for i in 0..<5 {
            XCTAssertEqual(controller.ingest(sample(backlog: 20, drop: 0, offset: Double(i))), .hold)
        }
        XCTAssertEqual(controller.currentBitrate, start)
    }

    /// A single spike must not move the bitrate — Wi-Fi RTT is noisy.
    func testSingleSpikeDoesNotTriggerAChange() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        XCTAssertEqual(controller.ingest(sample(backlog: 400, drop: 0, offset: 0)), .hold)
        XCTAssertEqual(controller.currentBitrate, 12_000_000)
    }

    func testSustainedHighRoundTripDecreasesBitrate() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        var decision: AdaptiveBitrateController.Decision = .hold
        for i in 0..<3 {
            decision = controller.ingest(sample(backlog: 300, drop: 0, offset: Double(i)))
        }
        guard case .decrease(let to) = decision else {
            return XCTFail("expected a decrease, got \(decision)")
        }
        XCTAssertEqual(to, 8_400_000)  // 12 Mbps * 0.7
        XCTAssertEqual(controller.currentBitrate, 8_400_000)
    }

    func testSustainedReceiverDropsDecreaseBitrate() {
        var controller = AdaptiveBitrateController(startingBitrate: 10_000_000)
        var decision: AdaptiveBitrateController.Decision = .hold
        // RTT healthy, but the receiver is shedding frames.
        for i in 0..<3 {
            decision = controller.ingest(sample(backlog: 15, drop: 0.30, offset: Double(i)))
        }
        guard case .decrease = decision else { return XCTFail("drops alone must trigger a cut") }
        XCTAssertLessThan(controller.currentBitrate, 10_000_000)
    }

    func testCooldownPreventsRepeatedCutsBeforeEffectIsVisible() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        for i in 0..<3 { _ = controller.ingest(sample(backlog: 300, drop: 0, offset: Double(i))) }
        let afterFirstCut = controller.currentBitrate

        // More bad samples immediately: inside the cooldown, so no further cut.
        for i in 3..<6 {
            XCTAssertEqual(controller.ingest(sample(backlog: 300, drop: 0, offset: Double(i) * 0.1 + 2.1)), .hold)
        }
        XCTAssertEqual(controller.currentBitrate, afterFirstCut)
    }

    func testContinuedCongestionCutsAgainAfterCooldown() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        for i in 0..<3 { _ = controller.ingest(sample(backlog: 300, drop: 0, offset: Double(i))) }
        let first = controller.currentBitrate

        var decision: AdaptiveBitrateController.Decision = .hold
        for i in 0..<3 {
            decision = controller.ingest(sample(backlog: 300, drop: 0, offset: 10 + Double(i)))
        }
        guard case .decrease(let to) = decision else { return XCTFail("expected a second cut") }
        XCTAssertLessThan(to, first)
    }

    func testNeverGoesBelowTheFloor() {
        var controller = AdaptiveBitrateController(
            startingBitrate: 2_000_000,
            limits: .init(minimum: 1_500_000, maximum: 20_000_000))
        // Hammer it with congestion far longer than needed.
        for i in 0..<200 {
            _ = controller.ingest(sample(backlog: 900, drop: 0.9, offset: Double(i) * 3))
        }
        XCTAssertEqual(controller.currentBitrate, 1_500_000)
    }

    func testRecoversUpwardOnlyAfterASustainedCleanRun() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        for i in 0..<3 { _ = controller.ingest(sample(backlog: 300, drop: 0, offset: Double(i))) }
        let reduced = controller.currentBitrate

        var decision: AdaptiveBitrateController.Decision = .hold
        // Recovery needs more evidence than a cut does.
        for i in 0..<8 {
            decision = controller.ingest(sample(backlog: 20, drop: 0, offset: 10 + Double(i)))
        }
        guard case .increase(let to) = decision else {
            return XCTFail("expected recovery, got \(decision)")
        }
        XCTAssertGreaterThan(to, reduced)
    }

    func testNeverExceedsTheCeiling() {
        var controller = AdaptiveBitrateController(
            startingBitrate: 19_500_000,
            limits: .init(minimum: 1_500_000, maximum: 20_000_000))
        for i in 0..<400 {
            _ = controller.ingest(sample(backlog: 5, drop: 0, offset: Double(i) * 3))
        }
        XCTAssertEqual(controller.currentBitrate, 20_000_000)
    }

    /// Between the two thresholds nothing should happen — that band is what stops
    /// the controller oscillating around a single trigger point.
    func testHysteresisBandHolds() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        // 90ms is above `clear` (60) and below `congested` (120).
        for i in 0..<40 {
            XCTAssertEqual(controller.ingest(sample(backlog: 90, drop: 0.02, offset: Double(i) * 3)), .hold)
        }
        XCTAssertEqual(controller.currentBitrate, 12_000_000)
    }

    /// Zero backlog means the receiver is caught up — which is genuinely good
    /// news, unlike the zero RTT this replaced, which meant "not measured".
    /// What must survive the change is that a quiet signal cannot silence a
    /// loud one: the receiver being caught up says nothing about whether it can
    /// decode what it has.
    func testBeingCaughtUpDoesNotMaskReceiverLoss() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        var decision: AdaptiveBitrateController.Decision = .hold
        for i in 0..<3 {
            decision = controller.ingest(sample(backlog: 0, drop: 0.40, offset: Double(i)))
        }
        XCTAssertTrue(decision.isDecrease, "drops must cut even with no backlog at all")
        XCTAssertLessThan(controller.currentBitrate, 12_000_000)
    }

    // MARK: - The bug this signal exists for

    /// A machine nobody touched must not come back blurry.
    ///
    /// ScreenCaptureKit sends nothing while the desktop is still — those frames
    /// arrive marked as carrying no new pixels and never reach the queue. The
    /// controller used to steer on `now - echoed`, the age of the receiver's
    /// newest frame, which therefore climbed by a second for every second the
    /// machine sat untouched. Past 120ms it read as congestion; three reports
    /// later the bitrate was cut, and cut again every cooldown until it hit the
    /// floor. Nothing about it was visible while it happened, and the only
    /// symptom was a picture that was soft for a few seconds after every break.
    ///
    /// Backlog cannot make that mistake: nothing was sent, so there is nothing
    /// to be behind on.
    func testAnIdleDesktopIsNotCongestion() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        let start = controller.currentBitrate

        // Two minutes of stillness, reported every half second. The receiver is
        // perfectly caught up the whole time, because nothing was sent.
        var decreases = 0
        for i in 0..<240 {
            if controller.ingest(sample(backlog: 0, offset: Double(i) * 0.5)).isDecrease {
                decreases += 1
            }
        }

        XCTAssertEqual(
            decreases, 0,
            "an untouched desktop was treated as a congested link \(decreases) times")
        XCTAssertGreaterThanOrEqual(
            controller.currentBitrate, start,
            "quality must not be lower for having been left alone")
    }

    // MARK: - The signals the controller was ignoring

    /// Covers backlog's blind spot.
    ///
    /// A link that stops taking bytes produces no new sends, so the receiver
    /// eventually acknowledges the last frame that got through and backlog
    /// reads zero — at the exact moment things are worst. Frames the send gate
    /// refused are measured on the sender and owe nothing to what the receiver
    /// claims about itself.
    func testFramesTheSocketRefusedAreCongestionOnTheirOwn() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        var decision: AdaptiveBitrateController.Decision = .hold
        for i in 0..<3 {
            // Every other signal says the link is perfect.
            decision = controller.ingest(sample(backlog: 0, shed: 0.25, offset: Double(i)))
        }
        XCTAssertTrue(
            decision.isDecrease,
            "a quarter of frames shed at the socket must cut, whatever the receiver says")
    }

    /// A receiver that took the bytes and cannot decode them fast enough. The
    /// number was already being reported and simply thrown away.
    func testAGrowingDecodeQueueIsCongestion() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        var decision: AdaptiveBitrateController.Decision = .hold
        for i in 0..<3 {
            decision = controller.ingest(sample(backlog: 10, queue: 9, offset: Double(i)))
        }
        XCTAssertTrue(decision.isDecrease, "a decoder nine frames behind will never catch up")
    }

    // MARK: - Direction rather than level

    /// Backlog building steadily must be acted on before it is large.
    ///
    /// Every sample here is BELOW the congested threshold, so a controller that
    /// only tests levels holds position and waits — while the delay it is
    /// waiting for is being paid by the user.
    func testBacklogBuildingIsActedOnBeforeItCrossesTheThreshold() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        var decision: AdaptiveBitrateController.Decision = .hold
        var highest = 0.0

        for i in 0..<5 {
            let backlog = 30 + Double(i) * 15  // 30, 45, 60, 75, 90
            highest = backlog
            decision = controller.ingest(sample(backlog: backlog, offset: Double(i) * 0.5))
        }

        XCTAssertTrue(decision.isDecrease, "steadily building backlog was not acted on")
        XCTAssertLessThan(
            highest, controller.thresholds.congestedBacklogMillis,
            "the point is that it fired at \(highest)ms, below the "
                + "\(controller.thresholds.congestedBacklogMillis)ms threshold")
    }

    /// A spike that has already drained must not still be acted on.
    ///
    /// This is where the noise floor earns its place, and it is not obvious:
    /// a least-squares slope lags reality by design, so for several reports
    /// after a spike has cleared the fitted line is still climbing steeply
    /// while the backlog it describes is back at zero. Acting on the trend
    /// alone would cut the bitrate *because* the link recovered — and then
    /// again on the next spike, which is how a controller ends up flapping.
    ///
    /// Requiring the backlog itself to still be elevated is what stops it.
    func testATrendThatHasAlreadyDrainedIsNotActedOn() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        var decisions: [AdaptiveBitrateController.Decision] = []

        // Quiet, one bad report, then fully recovered and staying that way.
        let backlogs: [Double] = [0, 0, 0, 90, 0, 0, 0, 0, 0, 0]
        for (i, backlog) in backlogs.enumerated() {
            decisions.append(controller.ingest(sample(backlog: backlog, offset: Double(i) * 0.5)))
        }

        XCTAssertFalse(
            decisions.contains(where: { $0.isDecrease }),
            "one spike, already drained, still cut the bitrate: \(decisions)")
    }

    /// A reconnect is a different path. A slope fitted across the gap describes
    /// neither side of it, and the first report after reconnecting would
    /// otherwise be compared against a link that no longer exists.
    func testReconnectingForgetsTheOldLink() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        for i in 0..<4 {
            _ = controller.ingest(sample(backlog: 30 + Double(i) * 15, offset: Double(i) * 0.5))
        }
        XCTAssertNotNil(controller.backlogSlope, "a trend was building")

        controller.resetLink()
        XCTAssertNil(controller.backlogSlope, "the old link's trend must not survive")

        // And the first samples after a reconnect cannot immediately cut on a
        // slope carried over from before.
        XCTAssertFalse(controller.ingest(sample(backlog: 90, offset: 100)).isDecrease)
    }

    func testOscillationConvergesRatherThanFlapping() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        var changes = 0
        // Alternating good/bad should not produce a change on every sample.
        for i in 0..<60 {
            let bad = i % 2 == 0
            let decision = controller.ingest(
                sample(backlog: bad ? 300 : 20, drop: 0, offset: Double(i) * 3))
            if decision != .hold { changes += 1 }
        }
        XCTAssertLessThan(changes, 6, "alternating conditions should not cause constant changes")
    }
}

extension AdaptiveBitrateController.Decision {
    var isDecrease: Bool {
        if case .decrease = self { return true }
        return false
    }
}
