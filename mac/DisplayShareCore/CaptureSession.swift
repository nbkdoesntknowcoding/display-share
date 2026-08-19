import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Captures a single display via ScreenCaptureKit and hands frames to a
/// bounded queue.
///
/// The capture callback does the minimum possible work — status check, enqueue,
/// return — because Phase 0 measured that doing real work there costs more than
/// half the frame rate. Everything downstream (JPEG in Task 1.3, H.264 in Task
/// 2.1) runs on its own thread draining `frames`.
public final class CaptureSession: NSObject, @unchecked Sendable {

    public struct Configuration: Sendable {
        public var displayID: CGDirectDisplayID
        public var fps: Int
        /// BGRA is convenient for JPEG in Phase 1; Phase 2 switches to NV12 to
        /// feed VideoToolbox without a conversion.
        public var pixelFormat: OSType
        public var showsCursor: Bool
        public var queueDepth: Int

        public init(
            displayID: CGDirectDisplayID,
            fps: Int = 60,
            pixelFormat: OSType = kCVPixelFormatType_32BGRA,
            showsCursor: Bool = true,
            queueDepth: Int = 2
        ) {
            self.displayID = displayID
            self.fps = fps
            self.pixelFormat = pixelFormat
            self.showsCursor = showsCursor
            self.queueDepth = queueDepth
        }
    }

    public enum CaptureError: Error, Equatable, CustomStringConvertible {
        case permissionDenied
        case displayNotFound(CGDirectDisplayID)
        case shareableContentFailed(String)
        case startFailed(String)

        public var description: String {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission has not been granted."
            case .displayNotFound(let id):
                return "ScreenCaptureKit cannot see display 0x\(String(id, radix: 16))."
            case .shareableContentFailed(let s):
                return "SCShareableContent failed: \(s)"
            case .startFailed(let s):
                return "SCStream.startCapture failed: \(s)"
            }
        }
    }

    public let frames: FrameQueue
    public private(set) var configuration: Configuration
    public private(set) var pixelSize: CGSize = .zero

    /// Frames ScreenCaptureKit marked as carrying no new pixels. An idle desktop
    /// produces these instead of resending an unchanged surface — they are not
    /// dropped frames and must not be counted as throughput.
    public private(set) var idleFrames = 0

    /// Raised when the stream stops on its own (display went away, permission revoked).
    public var onStreamStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private let callbackQueue = DispatchQueue(label: "in.theboringpeople.displayshare.capture")
    private let stateLock = NSLock()

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.frames = FrameQueue(capacity: configuration.queueDepth)
        super.init()
    }

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stream != nil
    }

    public func start() throws {
        // A freshly installed app has its own TCC identity with no Screen
        // Recording grant. Requesting raises the system prompt the first time;
        // afterwards the user must toggle it in System Settings. Task 6.3 turns
        // this into a proper onboarding flow.
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw CaptureError.permissionDenied
        }

        var shareable: SCShareableContent?
        var contentError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            shareable = content
            contentError = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw CaptureError.shareableContentFailed("timed out")
        }
        guard let content = shareable else {
            throw CaptureError.shareableContentFailed(contentError?.localizedDescription ?? "unknown")
        }
        guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) else {
            throw CaptureError.displayNotFound(configuration.displayID)
        }

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = display.width
        streamConfig.height = display.height
        streamConfig.pixelFormat = configuration.pixelFormat
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        streamConfig.showsCursor = configuration.showsCursor
        // SCK's own buffer pool. The comment below used to say "kept small" while
        // setting 6, which at 60fps is up to 100ms of frames waiting their turn.
        // Depth only helps a consumer that stalls and then catches up; ours is a
        // bounded queue of 2 that drops the oldest, so anything SCK holds back is
        // staleness we can never use. 3 is the documented practical floor.
        streamConfig.queueDepth = 3
        pixelSize = CGSize(width: display.width, height: display.height)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: callbackQueue)

        var startError: Error?
        let startSemaphore = DispatchSemaphore(value: 0)
        newStream.startCapture { error in
            startError = error
            startSemaphore.signal()
        }
        guard startSemaphore.wait(timeout: .now() + 10) == .success else {
            throw CaptureError.startFailed("timed out")
        }
        if let startError { throw CaptureError.startFailed("\(startError)") }

        stateLock.lock()
        stream = newStream
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        let current = stream
        stream = nil
        stateLock.unlock()

        guard let current else { return }
        let semaphore = DispatchSemaphore(value: 0)
        current.stopCapture { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 5)
        frames.close()
    }

    /// Live fps change without rebuilding the stream.
    public func updateFrameRate(_ fps: Int) {
        configuration.fps = fps
        stateLock.lock()
        let current = stream
        stateLock.unlock()
        guard let current else { return }

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = Int(pixelSize.width)
        streamConfig.height = Int(pixelSize.height)
        streamConfig.pixelFormat = configuration.pixelFormat
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        streamConfig.showsCursor = configuration.showsCursor
        streamConfig.queueDepth = 6
        current.updateConfiguration(streamConfig) { _ in }
    }
}

extension CaptureSession: SCStreamOutput, SCStreamDelegate {

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }

        // Anything other than .complete carries no new pixels.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw),
            status != .complete
        {
            idleFrames += 1
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // The ONLY work done on the capture thread. Never blocks.
        frames.enqueue(pixelBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        self.stream = nil
        stateLock.unlock()
        frames.close()
        onStreamStopped?(error)
    }
}
