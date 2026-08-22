import XCTest

@testable import DisplayShareCore

/// The gate is pure, so the shed-versus-queue policy is tested by driving the
/// state machine rather than by congesting a real network. What this file
/// cannot show is that the gate ever *closes* in production — that depends on
/// Network.framework delaying the `.contentProcessed` completion under a full
/// send buffer, which only a constrained link exercises. See
/// mac/scripts/backpressure-acceptance.py for that half.
final class SendGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testSendsWhenNothingIsOutstanding() {
        var gate = SendGate()
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertTrue(gate.isSendOutstanding)
    }

    /// The whole point: the encoder never runs more than one access unit ahead
    /// of the socket.
    func testShedsEveryFrameOfferedWhileASendIsOutstanding() {
        var gate = SendGate()
        XCTAssertEqual(gate.offer(), .send)
        for _ in 0..<10 {
            XCTAssertEqual(gate.offer(), .drop)
        }
        XCTAssertTrue(gate.isSendOutstanding)
    }

    func testCompletionReopensTheGate() {
        var gate = SendGate()
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertFalse(gate.completed(at: t0))
        XCTAssertFalse(gate.isSendOutstanding)
        XCTAssertEqual(gate.offer(), .send)
    }

    /// A clean stream must never force keyframes — that would cost bandwidth
    /// for nothing.
    func testNoRepairRequestedWhenNothingWasShed() {
        var gate = SendGate()
        for i in 0..<20 {
            XCTAssertEqual(gate.offer(), .send)
            XCTAssertFalse(
                gate.completed(at: t0.addingTimeInterval(Double(i))),
                "a stream that never drops must not force an IDR")
        }
    }

    /// The receiver cannot detect the gap itself, so the drop has to produce a
    /// repair request on this side.
    func testAShedFrameRequestsARepairKeyframe() {
        var gate = SendGate()
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertEqual(gate.offer(), .drop)
        XCTAssertTrue(gate.completed(at: t0))
    }

    /// Keyframes are the largest frames on the wire; one per shed frame would
    /// deepen the congestion that caused the drop. SPEC §4.5 sets the ceiling.
    func testRepairRequestsAreRateLimited() {
        var gate = SendGate()
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertEqual(gate.offer(), .drop)
        XCTAssertTrue(gate.completed(at: t0))

        // Still inside the 250ms window.
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertEqual(gate.offer(), .drop)
        XCTAssertFalse(gate.completed(at: t0.addingTimeInterval(0.1)))
    }

    /// The failure this guards against: a drop that lands inside the rate-limit
    /// window silently forgetting its repair, leaving the receiver corrupt
    /// until the next natural keyframe two seconds later.
    func testARepairSuppressedByTheRateLimitIsRetriedNotForgotten() {
        var gate = SendGate()
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertEqual(gate.offer(), .drop)
        XCTAssertTrue(gate.completed(at: t0))

        // Shed again immediately; the repair is owed but must wait.
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertEqual(gate.offer(), .drop)
        XCTAssertFalse(gate.completed(at: t0.addingTimeInterval(0.05)))

        // No further drops. Once the window passes the owed repair still fires.
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertTrue(
            gate.completed(at: t0.addingTimeInterval(0.30)),
            "a suppressed repair must be retried, not dropped on the floor")

        // And then the debt is settled.
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertFalse(gate.completed(at: t0.addingTimeInterval(1.0)))
    }

    /// Sustained congestion: many drops, but repair requests stay bounded.
    func testSustainedCongestionDoesNotStormKeyframes() {
        var gate = SendGate()
        var repairs = 0
        // 5 seconds at 60fps, dropping every other frame.
        for i in 0..<300 {
            let now = t0.addingTimeInterval(Double(i) / 60.0)
            XCTAssertEqual(gate.offer(), .send)
            XCTAssertEqual(gate.offer(), .drop)
            if gate.completed(at: now) { repairs += 1 }
        }
        // 250ms ceiling over 5s allows at most 21 including the one at t0.
        XCTAssertLessThanOrEqual(repairs, 21, "keyframe storm under congestion")
        XCTAssertGreaterThan(repairs, 15, "congestion must still be repaired")
    }

    func testResetForgetsTheOutstandingSendAndTheDamage() {
        var gate = SendGate()
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertEqual(gate.offer(), .drop)

        gate.reset()

        XCTAssertFalse(gate.isSendOutstanding)
        XCTAssertEqual(gate.offer(), .send)
        XCTAssertFalse(
            gate.completed(at: t0),
            "a fresh socket has missed nothing and needs no repair")
    }
}
