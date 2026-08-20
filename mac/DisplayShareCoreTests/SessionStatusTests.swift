import XCTest

@testable import DisplayShareCore

/// Command 6 of the UI/UX audit. The popover showed a GREEN dot beside 0.0 Mbps
/// while the Windows client was being refused — green meaning live, next to a
/// number meaning nothing was flowing.
///
/// These assert the rule that prevents it: live means frames are reaching a
/// receiver, and nothing else does.
final class SessionStatusTests: XCTestCase {

    private func derive(
        active: Bool = true, starting: Bool = false, failure: String? = nil,
        connected: Bool = true, mbps: Double = 12, dropped: Int = 0,
        client: String? = "JASON_MISTRESS"
    ) -> SessionStatus {
        .derive(
            isActive: active, isStarting: starting, failure: failure,
            connected: connected, megabitsPerSecond: mbps, client: client,
            droppedFrames: dropped
        )
    }

    func testAttachedButNothingFlowingIsWaitingNotStreaming() {
        // The exact case the audit caught: a socket is attached, the bitrate is
        // zero, and the old code called that healthy.
        XCTAssertEqual(derive(mbps: 0.0), .waiting)
        XCTAssertEqual(derive(mbps: 0.01), .waiting)
    }

    func testRunningWithNobodyAttachedIsWaiting() {
        // Running is not streaming. Nobody is watching this screen.
        XCTAssertEqual(derive(connected: false, mbps: 0), .waiting)
        // Even a stale bitrate reading must not promote it.
        XCTAssertEqual(derive(connected: false, mbps: 9), .waiting)
    }

    func testStreamingRequiresBothAttachedAndFlowing() {
        XCTAssertEqual(derive(), .streaming(client: "JASON_MISTRESS"))
    }

    func testDroppedFramesReadAsDegradedRatherThanHealthy() {
        XCTAssertEqual(derive(dropped: 12), .degraded(client: "JASON_MISTRESS"))
    }

    func testFailureBeatsEveryOtherSignal() {
        // A failure while the stats still look live must not be hidden by them.
        let status = derive(failure: "Mac went to sleep", connected: true, mbps: 12)
        XCTAssertEqual(status, .failed("Mac went to sleep"))
        XCTAssertEqual(status.detail, "Mac went to sleep")
    }

    func testIdleAndStartingAreDistinct() {
        XCTAssertEqual(derive(active: false, connected: false, mbps: 0), .idle)
        XCTAssertEqual(derive(starting: true), .starting)
    }

    func testOnlyStreamingStatesShowMetrics() {
        // Metrics beside a waiting state is how "0.0 Mbps" got on screen at all.
        XCTAssertFalse(SessionStatus.idle.showsMetrics)
        XCTAssertFalse(SessionStatus.waiting.showsMetrics)
        XCTAssertFalse(SessionStatus.starting.showsMetrics)
        XCTAssertFalse(SessionStatus.failed("x").showsMetrics)
        XCTAssertTrue(SessionStatus.streaming(client: nil).showsMetrics)
        XCTAssertTrue(SessionStatus.degraded(client: nil).showsMetrics)
    }

    func testHeadlinesNeverLeakInternalDetail() {
        // The audit found "Display 0xb" — a raw CGDirectDisplayID — and an
        // internal "(Task 3.3)" reference shipped to users.
        let statuses: [SessionStatus] = [
            .idle, .starting, .waiting, .streaming(client: "PC"),
            .degraded(client: "PC"), .failed("Disconnected"),
        ]
        for status in statuses {
            let text = status.headline + " " + (status.detail ?? "")
            XCTAssertFalse(text.contains("0x"), "leaks a display id: \(text)")
            XCTAssertNil(text.range(of: #"Task \d|Phase \d"#, options: .regularExpression),
                         "leaks an internal reference: \(text)")
        }
    }

    func testAnUnnamedClientStillReadsAsASentence() {
        XCTAssertEqual(SessionStatus.streaming(client: nil).headline, "Sharing to your PC")
    }

    func testWaitingPulsesAndStreamingDoesNot() {
        // Pulse means "expect this to change shortly"; a healthy stream is not
        // waiting for anything.
        XCTAssertTrue(SessionStatus.waiting.pulses)
        XCTAssertFalse(SessionStatus.streaming(client: nil).pulses)
    }
}
