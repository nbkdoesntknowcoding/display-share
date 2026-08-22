import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest

@testable import DisplayShareCore

/// Guards the capture stream configuration against the drift that already
/// happened once: `start()` set ScreenCaptureKit's `queueDepth` to 3 and
/// `updateFrameRate(_:)` set it to 6, so every live frame rate change put the
/// deep queue — up to 100ms of stale frames at 60fps — back.
///
/// These assert literal values on purpose. Comparing against
/// `CaptureSession.streamQueueDepth` would pass no matter what that constant
/// became, which is the kind of coverage that is worse than none.
final class CaptureSessionTests: XCTestCase {

    private func makeSession(
        fps: Int = 60,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        showsCursor: Bool = true
    ) -> CaptureSession {
        CaptureSession(
            configuration: .init(
                displayID: 0, fps: fps, pixelFormat: pixelFormat, showsCursor: showsCursor))
    }

    /// 3 is the number the latency work chose. If someone raises it, that should
    /// be a decision, not a merge artifact.
    func testStreamQueueDepthIsThree() {
        let config = makeSession().makeStreamConfiguration(width: 1920, height: 1080, fps: 60)
        XCTAssertEqual(config.queueDepth, 3)
    }

    /// The regression itself: changing frame rate must not change queue depth.
    func testQueueDepthSurvivesEveryFrameRate() {
        let session = makeSession()
        for fps in [15, 24, 30, 60, 120] {
            let config = session.makeStreamConfiguration(width: 1920, height: 1080, fps: fps)
            XCTAssertEqual(config.queueDepth, 3, "queue depth drifted at \(fps)fps")
        }
    }

    /// `updateConfiguration` replaces the whole configuration, so a field the
    /// fps-change path forgets is a field it silently changes. Only the frame
    /// interval may differ between two builds of the same stream.
    func testOnlyFrameIntervalDiffersAcrossFrameRates() {
        let session = makeSession(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  showsCursor: false)
        let atSixty = session.makeStreamConfiguration(width: 2560, height: 1440, fps: 60)
        let atThirty = session.makeStreamConfiguration(width: 2560, height: 1440, fps: 30)

        XCTAssertEqual(atSixty.width, atThirty.width)
        XCTAssertEqual(atSixty.height, atThirty.height)
        XCTAssertEqual(atSixty.pixelFormat, atThirty.pixelFormat)
        XCTAssertEqual(atSixty.showsCursor, atThirty.showsCursor)
        XCTAssertEqual(atSixty.queueDepth, atThirty.queueDepth)

        XCTAssertEqual(atThirty.minimumFrameInterval, CMTime(value: 1, timescale: 30))
        XCTAssertEqual(atSixty.minimumFrameInterval, CMTime(value: 1, timescale: 60))
    }

    /// The builder must carry the session's own configuration through, not
    /// defaults — the cursor and pixel format are wire-visible.
    func testBuilderCarriesSessionConfiguration() {
        let session = makeSession(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, showsCursor: false)
        let config = session.makeStreamConfiguration(width: 1280, height: 720, fps: 30)

        XCTAssertEqual(config.width, 1280)
        XCTAssertEqual(config.height, 720)
        XCTAssertFalse(config.showsCursor)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    /// SCK's pool and our `FrameQueue` are different numbers for different
    /// reasons; the shared name has confused this once already.
    func testFrameQueueCapacityIsIndependentOfStreamQueueDepth() {
        let session = CaptureSession(configuration: .init(displayID: 0, fps: 60, queueDepth: 2))
        let config = session.makeStreamConfiguration(width: 1920, height: 1080, fps: 60)
        XCTAssertEqual(session.configuration.queueDepth, 2)
        XCTAssertEqual(config.queueDepth, 3)
    }
}
