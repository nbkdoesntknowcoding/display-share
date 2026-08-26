import XCTest

@testable import DisplayShareCore

/// Choosing a rate the receiver's panel can show evenly.
///
/// The failure this prevents does not look like a bug. Every number reads
/// healthy — no dropped frames, no backlog, no shed frames — and the picture
/// still stutters, because the panel is holding frames for alternating numbers
/// of refreshes. It is invisible to every measurement the app has.
final class CadenceTests: XCTestCase {

    /// The common pairs. Most machines are one of these, and none should move.
    func testRatesThatAlreadyDivideEvenlyAreLeftAlone() {
        XCTAssertEqual(Cadence.rate(preferred: 60, panelRefresh: 120), 60)
        XCTAssertEqual(Cadence.rate(preferred: 30, panelRefresh: 60), 30)
        XCTAssertEqual(Cadence.rate(preferred: 60, panelRefresh: 60), 60)
        XCTAssertEqual(Cadence.rate(preferred: 120, panelRefresh: 240), 120)
    }

    /// The case worth having this for. 60 into 144 is 2.4 refreshes a frame,
    /// which the panel shows as 2, 2, 3, 2, 2, 3 — a beat, not a stutter, and
    /// no measurement in the app can see it.
    func testAGamingPanelSnapsToARateItCanHoldSteady() {
        let rate = Cadence.rate(preferred: 60, panelRefresh: 144)
        XCTAssertEqual(rate, 48)
        XCTAssertTrue(Cadence.isEven(rate: rate, panelRefresh: 144))
    }

    /// And the case where snapping is the worse deal. 75Hz divides into 25,
    /// 15, 5 — taking any of them to fix the cadence would cost more than half
    /// the frame rate.
    func testAPanelWithNoNearbyDivisorKeepsTheRequestedRate() {
        XCTAssertEqual(
            Cadence.rate(preferred: 60, panelRefresh: 75), 60,
            "25fps is not a fair price for an even cadence")
    }

    /// Never upward. Reaching a divisor by asking for MORE frames spends encode
    /// time and bandwidth the user did not ask for, on a machine that may
    /// already be the reason the rate was lowered.
    func testTheRateIsNeverRaisedToReachADivisor() {
        for panel in [60, 75, 90, 120, 144, 165, 240] {
            for preferred in [24, 30, 48, 60] {
                XCTAssertLessThanOrEqual(
                    Cadence.rate(preferred: preferred, panelRefresh: panel), preferred,
                    "raised \(preferred) on a \(panel)Hz panel")
            }
        }
    }

    /// The panel is the ceiling: no rate above its refresh can be shown evenly,
    /// and sending frames it cannot show is work thrown away.
    func testARateAboveThePanelIsCappedAtThePanel() {
        XCTAssertEqual(Cadence.rate(preferred: 120, panelRefresh: 60), 60)
        XCTAssertEqual(Cadence.rate(preferred: 240, panelRefresh: 144), 144)
    }

    /// A receiver that reports nothing gets exactly what was asked for. A zero
    /// is an absent measurement, and guessing from it would be worse than
    /// leaving the choice alone.
    func testAnUnknownPanelChangesNothing() {
        XCTAssertEqual(Cadence.rate(preferred: 60, panelRefresh: 0), 60)
        XCTAssertEqual(Cadence.rate(preferred: 60, panelRefresh: -1), 60)
        XCTAssertEqual(Cadence.rate(preferred: 0, panelRefresh: 120), 0)
    }

    /// Whatever comes back must be shown evenly, or be the rate that was asked
    /// for. Those are the only two honest outcomes, and this checks every
    /// combination rather than the handful anyone would think to write down.
    func testEveryResultIsEitherEvenOrExactlyWhatWasAsked() {
        for panel in 1...240 {
            for preferred in 1...120 {
                let rate = Cadence.rate(preferred: preferred, panelRefresh: panel)
                XCTAssertTrue(
                    Cadence.isEven(rate: rate, panelRefresh: panel) || rate == preferred,
                    "\(preferred)fps on \(panel)Hz became \(rate), which is neither even nor asked for"
                )
                XCTAssertGreaterThan(rate, 0, "\(preferred)fps on \(panel)Hz became \(rate)")
            }
        }
    }

    /// The loss is bounded by the tolerance, so this can never quietly halve
    /// someone's frame rate in the name of smoothness.
    func testTheRateIsNeverCutByMoreThanTheTolerance() {
        for panel in 1...240 {
            for preferred in 1...120 {
                let rate = Cadence.rate(preferred: preferred, panelRefresh: panel)
                guard rate != preferred, preferred <= panel else { continue }
                let loss = Double(preferred - rate) / Double(preferred)
                XCTAssertLessThanOrEqual(
                    loss, Cadence.tolerance + 0.0001,
                    "\(preferred)fps on \(panel)Hz was cut to \(rate)")
            }
        }
    }
}
