import XCTest

@testable import DisplayShareCore

/// The evidence the bitrate controller steers on.
///
/// These are pure, and they are where the idle-desktop bug is actually fixed:
/// the controller was always reasonable about its inputs, and the input was
/// wrong. Testing the controller alone would not have caught it.
final class CongestionSignalTests: XCTestCase {

    // MARK: - Backlog

    /// The property that fixes the bug, stated on its own.
    ///
    /// The old signal was `now - echoed`: the age of the receiver's newest
    /// frame, which grows with the clock whether or not anything was sent. An
    /// idle desktop sends nothing — ScreenCaptureKit marks those frames as
    /// carrying no new pixels and they never reach the queue — so that number
    /// climbed by a second for every second nobody touched the machine, and the
    /// controller cut the bitrate to the floor for it.
    ///
    /// Backlog contains no clock at all. Both operands are timestamps the
    /// sender minted, so wall time cannot enter the measurement.
    func testBacklogDoesNotGrowWithTimeOnlyWithUnacknowledgedVideo() {
        // One frame sent, receiver acknowledged it, nothing since.
        let sent: UInt64 = 5_000_000

        for _ in 0..<10 {
            // However long a caller waits between asking, the answer is the
            // same, because neither operand moved.
            XCTAssertEqual(
                CongestionSignal.backlogMillis(newestSent: sent, echoed: sent), 0,
                "a caught-up receiver is not a congested link")
        }
    }

    func testBacklogIsTheVideoTheReceiverHasNotCaughtUpWith() {
        // The receiver's newest frame is 250ms of video behind the newest sent.
        XCTAssertEqual(
            CongestionSignal.backlogMillis(newestSent: 1_250_000, echoed: 1_000_000), 250)
    }

    /// An echo we never sent. A receiver ahead of us is not a receiver 
    /// negatively behind us, and unsigned arithmetic would wrap it into an
    /// enormous positive backlog and cut the bitrate to the floor.
    func testAnEchoFromTheFutureIsNotAnEnormousBacklog() {
        XCTAssertEqual(
            CongestionSignal.backlogMillis(newestSent: 1_000_000, echoed: 9_000_000), 0)
    }

    // MARK: - Trend

    func testASteadyClimbReportsItsRate() {
        var trend = BacklogTrend()
        let start = Date(timeIntervalSince1970: 1_000_000)
        // 20ms more backlog every half second — 40ms per second.
        for i in 0..<6 {
            trend.note(
                backlogMillis: Double(i) * 20, at: start.addingTimeInterval(Double(i) * 0.5))
        }
        let slope = try? XCTUnwrap(trend.slopeMillisPerSecond)
        XCTAssertEqual(slope ?? 0, 40, accuracy: 0.001)
    }

    /// A link recovering must read as recovering, not merely as "not building".
    func testDrainingReportsANegativeRate() {
        var trend = BacklogTrend()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<6 {
            trend.note(
                backlogMillis: 200 - Double(i) * 20, at: start.addingTimeInterval(Double(i) * 0.5))
        }
        XCTAssertLessThan(trend.slopeMillisPerSecond ?? 0, -1)
    }

    func testASteadyBacklogHasNoTrend() {
        var trend = BacklogTrend()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<6 {
            trend.note(backlogMillis: 80, at: start.addingTimeInterval(Double(i) * 0.5))
        }
        XCTAssertEqual(trend.slopeMillisPerSecond ?? .nan, 0, accuracy: 0.001)
    }

    /// Two points define a line through them and say nothing about a trend.
    func testATrendNeedsEnoughPointsToBeOne() {
        var trend = BacklogTrend()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(trend.slopeMillisPerSecond, "no samples")
        trend.note(backlogMillis: 10, at: start)
        XCTAssertNil(trend.slopeMillisPerSecond, "one sample")
        trend.note(backlogMillis: 90, at: start.addingTimeInterval(0.5))
        XCTAssertNil(trend.slopeMillisPerSecond, "two samples are a line, not a trend")
    }

    /// Reports that share a timestamp are a vertical line. Fitting one divides
    /// by zero, and an infinite slope would read as congestion forever.
    func testSamplesAtTheSameInstantHaveNoSlope() {
        var trend = BacklogTrend()
        let moment = Date(timeIntervalSince1970: 1_000_000)
        for backlog in [10.0, 200.0, 400.0] { trend.note(backlogMillis: backlog, at: moment) }
        XCTAssertNil(trend.slopeMillisPerSecond)
    }

    /// The window must roll, or a stall from ten minutes ago still tilts the
    /// line and the controller never believes the link recovered.
    func testTheWindowForgets() {
        var trend = BacklogTrend(window: 4)
        let start = Date(timeIntervalSince1970: 1_000_000)

        // A steep climb, then a flat run long enough to fill the window.
        for i in 0..<4 {
            trend.note(
                backlogMillis: Double(i) * 100, at: start.addingTimeInterval(Double(i) * 0.5))
        }
        XCTAssertGreaterThan(trend.slopeMillisPerSecond ?? 0, 100, "the climb is visible")

        for i in 4..<8 {
            trend.note(backlogMillis: 300, at: start.addingTimeInterval(Double(i) * 0.5))
        }
        XCTAssertEqual(
            trend.slopeMillisPerSecond ?? .nan, 0, accuracy: 0.001,
            "the old climb must have rolled out of the window")
    }

    func testResetForgetsEverything() {
        var trend = BacklogTrend()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<6 {
            trend.note(
                backlogMillis: Double(i) * 20, at: start.addingTimeInterval(Double(i) * 0.5))
        }
        XCTAssertNotNil(trend.slopeMillisPerSecond)
        trend.reset()
        XCTAssertNil(trend.slopeMillisPerSecond)
    }
}
