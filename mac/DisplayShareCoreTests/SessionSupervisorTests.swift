import XCTest

@testable import DisplayShareCore

/// When silence is a fault and when it is just quiet.
///
/// The supervisor restarts capture when it stops making progress, which is
/// right — a stream that dies takes the session with it and nothing else
/// notices. What it could not do was tell a dead stream from a still desktop,
/// and it resolved that the expensive way: past the timeout it tore capture
/// down, rebuilt it and forced a keyframe, every six seconds, for as long as
/// nobody touched the machine.
///
/// Nothing about that is visible in a build. It needs a desktop left alone for
/// longer than the timeout, which is exactly the situation nobody is watching.
final class SessionSupervisorTests: XCTestCase {

    /// The supervisor with its providers wired to values a test controls.
    private func supervisor(
        heartbeat: @escaping () -> Int,
        recovered: @escaping () -> Void
    ) -> SessionSupervisor {
        let supervisor = SessionSupervisor()
        supervisor.hasReceiver = { true }
        supervisor.captureHeartbeatProvider = heartbeat
        supervisor.onRecoverCapture = {
            recovered()
            return true
        }
        return supervisor
    }

    // MARK: - The bug

    /// A desktop nobody is touching must be left alone.
    ///
    /// ScreenCaptureKit sends frames marked as carrying no new pixels rather
    /// than resending an unchanged surface, so a still desktop encodes nothing
    /// while the stream is perfectly healthy. Those frames are what the
    /// heartbeat counts, and counting them is the whole fix.
    func testAStillDesktopIsNotARecoveryEvent() {
        var beats = 0
        var recoveries = 0
        let supervisor = supervisor(heartbeat: { beats }, recovered: { recoveries += 1 })
        supervisor.stallTimeout = 0.05

        // Idle frames keep arriving; nothing is ever encoded.
        for _ in 0..<40 {
            beats += 1
            supervisor.checkProgress()
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(
            recoveries, 0,
            "capture was restarted \(recoveries) times on a desktop that was simply still")
    }

    /// And a stream that really has stopped must still be caught.
    ///
    /// The timeout is deliberately tiny and the wait several times longer, so
    /// this asserts that recovery HAPPENS rather than that it happens quickly.
    /// A slow machine can only make it more certain, which is the right way
    /// round for a timing-dependent test.
    func testAStreamThatStopsDeliveringIsRecovered() {
        var recoveries = 0
        let supervisor = supervisor(heartbeat: { 7 }, recovered: { recoveries += 1 })
        supervisor.stallTimeout = 0.1

        supervisor.checkProgress()
        Thread.sleep(forTimeInterval: 0.4)
        supervisor.checkProgress()

        XCTAssertGreaterThan(
            recoveries, 0, "a frozen heartbeat past the timeout must restart capture")
    }

    /// No receiver means nothing is expected, so silence is not evidence of
    /// anything. This predates the heartbeat and must survive it.
    func testSilenceWithNoReceiverIsNotAStall() {
        var recoveries = 0
        let supervisor = supervisor(heartbeat: { 0 }, recovered: { recoveries += 1 })
        supervisor.hasReceiver = { false }
        supervisor.stallTimeout = 0.05

        supervisor.checkProgress()
        Thread.sleep(forTimeInterval: 0.2)
        supervisor.checkProgress()

        XCTAssertEqual(recoveries, 0, "nobody was watching; there was nothing to recover")
    }
}
