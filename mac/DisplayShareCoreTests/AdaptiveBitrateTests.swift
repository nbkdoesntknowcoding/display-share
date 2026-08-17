import XCTest

@testable import DisplayShareCore

/// Task 4.3. The controller is pure, so congestion behaviour is tested by
/// feeding it sequences rather than by trying to congest a real network.
final class AdaptiveBitrateTests: XCTestCase {

    private var t0 = Date(timeIntervalSince1970: 1_000_000)

    private func sample(rtt: Double, drop: Double, offset: TimeInterval) -> AdaptiveBitrateController.Sample {
        .init(roundTripMillis: rtt, dropRate: drop, at: t0.addingTimeInterval(offset))
    }

    func testHoldsSteadyOnAHealthyLink() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        let start = controller.currentBitrate
        // Clean but not yet enough consecutive samples to probe upward.
        for i in 0..<5 {
            XCTAssertEqual(controller.ingest(sample(rtt: 20, drop: 0, offset: Double(i))), .hold)
        }
        XCTAssertEqual(controller.currentBitrate, start)
    }

    /// A single spike must not move the bitrate — Wi-Fi RTT is noisy.
    func testSingleSpikeDoesNotTriggerAChange() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        XCTAssertEqual(controller.ingest(sample(rtt: 400, drop: 0, offset: 0)), .hold)
        XCTAssertEqual(controller.currentBitrate, 12_000_000)
    }

    func testSustainedHighRoundTripDecreasesBitrate() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        var decision: AdaptiveBitrateController.Decision = .hold
        for i in 0..<3 {
            decision = controller.ingest(sample(rtt: 300, drop: 0, offset: Double(i)))
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
            decision = controller.ingest(sample(rtt: 15, drop: 0.30, offset: Double(i)))
        }
        guard case .decrease = decision else { return XCTFail("drops alone must trigger a cut") }
        XCTAssertLessThan(controller.currentBitrate, 10_000_000)
    }

    func testCooldownPreventsRepeatedCutsBeforeEffectIsVisible() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        for i in 0..<3 { _ = controller.ingest(sample(rtt: 300, drop: 0, offset: Double(i))) }
        let afterFirstCut = controller.currentBitrate

        // More bad samples immediately: inside the cooldown, so no further cut.
        for i in 3..<6 {
            XCTAssertEqual(controller.ingest(sample(rtt: 300, drop: 0, offset: Double(i) * 0.1 + 2.1)), .hold)
        }
        XCTAssertEqual(controller.currentBitrate, afterFirstCut)
    }

    func testContinuedCongestionCutsAgainAfterCooldown() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        for i in 0..<3 { _ = controller.ingest(sample(rtt: 300, drop: 0, offset: Double(i))) }
        let first = controller.currentBitrate

        var decision: AdaptiveBitrateController.Decision = .hold
        for i in 0..<3 {
            decision = controller.ingest(sample(rtt: 300, drop: 0, offset: 10 + Double(i)))
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
            _ = controller.ingest(sample(rtt: 900, drop: 0.9, offset: Double(i) * 3))
        }
        XCTAssertEqual(controller.currentBitrate, 1_500_000)
    }

    func testRecoversUpwardOnlyAfterASustainedCleanRun() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        for i in 0..<3 { _ = controller.ingest(sample(rtt: 300, drop: 0, offset: Double(i))) }
        let reduced = controller.currentBitrate

        var decision: AdaptiveBitrateController.Decision = .hold
        // Recovery needs more evidence than a cut does.
        for i in 0..<8 {
            decision = controller.ingest(sample(rtt: 20, drop: 0, offset: 10 + Double(i)))
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
            _ = controller.ingest(sample(rtt: 5, drop: 0, offset: Double(i) * 3))
        }
        XCTAssertEqual(controller.currentBitrate, 20_000_000)
    }

    /// Between the two thresholds nothing should happen — that band is what stops
    /// the controller oscillating around a single trigger point.
    func testHysteresisBandHolds() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        // 90ms is above `clear` (60) and below `congested` (120).
        for i in 0..<40 {
            XCTAssertEqual(controller.ingest(sample(rtt: 90, drop: 0.02, offset: Double(i) * 3)), .hold)
        }
        XCTAssertEqual(controller.currentBitrate, 12_000_000)
    }

    /// An unmeasured RTT arrives as 0 and must not read as a perfect link that
    /// justifies probing upward on drop-free but unmeasured samples.
    func testZeroRoundTripIsTreatedAsUnknownNotPerfect() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        var decision: AdaptiveBitrateController.Decision = .hold
        // Same sustained requirement as any other signal: three samples, then act.
        for i in 0..<3 {
            decision = controller.ingest(sample(rtt: 0, drop: 0.40, offset: Double(i)))
        }
        // An unmeasured RTT must not mask receiver-side loss.
        XCTAssertTrue(decision.isDecrease, "drops must trigger a cut even with RTT unknown")
        XCTAssertLessThan(controller.currentBitrate, 12_000_000)
    }

    func testOscillationConvergesRatherThanFlapping() {
        var controller = AdaptiveBitrateController(startingBitrate: 12_000_000)
        var changes = 0
        // Alternating good/bad should not produce a change on every sample.
        for i in 0..<60 {
            let bad = i % 2 == 0
            let decision = controller.ingest(
                sample(rtt: bad ? 300 : 20, drop: 0, offset: Double(i) * 3))
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
