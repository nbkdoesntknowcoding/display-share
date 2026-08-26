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
        /// Capacity of OUR `FrameQueue`. Not ScreenCaptureKit's buffer pool —
        /// that is `streamQueueDepth`, and the two are deliberately different
        /// numbers for different reasons.
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

    /// Frames arriving while capture is suspended or stopped.
    ///
    /// Counted apart from `idleFrames` because they mean the opposite thing.
    /// An idle frame says "nothing changed"; a suspended one says "you are not
    /// being shown anything" — a locked screen, a display asleep, a stream
    /// macOS has paused. Both look like silence downstream, and treating the
    /// second as ordinary quiet is how a genuinely dead capture goes unnoticed.
    public private(set) var suspendedFrames = 0

    /// Evidence that ScreenCaptureKit is still delivering.
    ///
    /// Advances for every frame that arrives with something to say, whether or
    /// not it carries pixels — so a desktop nobody is touching still proves the
    /// stream is alive. Deliberately excludes suspended and stopped frames:
    /// those are not the stream working, and counting them would suppress the
    /// recovery they should trigger.
    ///
    /// This exists because the supervisor cannot otherwise tell "nothing
    /// changed" from "nothing is coming", and it was resolving that ambiguity
    /// the expensive way — restarting capture and forcing a keyframe every six
    /// seconds while somebody read a document.
    public var captureHeartbeat: Int {
        countersLock.lock(); defer { countersLock.unlock() }
        return heartbeat
    }
    private var heartbeat = 0

    /// Its own lock, not `stateLock`.
    ///
    /// These counters are written from the capture callback, which is
    /// documented below as never blocking. `stateLock` is held across session
    /// teardown, so borrowing it here would make the delivery thread wait on
    /// work that has nothing to do with counting. This one is only ever held
    /// for an increment or a read.
    private let countersLock = NSLock()

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

        let streamConfig = makeStreamConfiguration(
            width: display.width, height: display.height, fps: configuration.fps)
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

        let streamConfig = makeStreamConfiguration(
            width: Int(pixelSize.width), height: Int(pixelSize.height), fps: fps)
        current.updateConfiguration(streamConfig) { error in
            guard let error else { return }
            // The stream keeps running at its previous rate, so `configuration.fps`
            // now overstates what is actually being captured. Nothing downstream can
            // recover from that, but silence would leave a wrong frame rate looking
            // like a successful one.
            FileHandle.standardError.write(Data(
                "[DisplayShare] capture: frame rate change to \(fps)fps failed: \(error)\n".utf8))
        }
    }

    /// The single `SCStreamConfiguration` both paths build.
    ///
    /// It exists because there were two of these and they disagreed: `start()`
    /// set `queueDepth` 3 while `updateFrameRate(_:)` set 6, so a live frame rate
    /// change silently reverted the shallower queue. Every field here has to be
    /// set on both paths anyway — `updateConfiguration` replaces the whole
    /// configuration, so a field omitted from the update is a field changed by
    /// it — which makes one builder both the fix and the thing that stops it
    /// happening again.
    func makeStreamConfiguration(width: Int, height: Int, fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = configuration.pixelFormat
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = configuration.showsCursor
        config.queueDepth = Self.streamQueueDepth
        return config
    }

    /// ScreenCaptureKit's own buffer pool, in frames.
    ///
    /// This was 6 under a comment claiming the queue was "kept small" — at 60fps,
    /// up to 100ms of frames waiting their turn. Depth only helps a consumer that
    /// stalls and then catches up; ours is a `FrameQueue` of 2 that drops the
    /// oldest, so anything SCK holds back is staleness we can never use. 3 is the
    /// documented practical floor.
    static let streamQueueDepth = 3
}

extension CaptureSession: SCStreamOutput, SCStreamDelegate {

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }

        // Anything other than .complete carries no new pixels — but WHICH of
        // them it is decides whether silence downstream is normal.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw),
            status != .complete
        {
            switch status {
            case .suspended, .stopped:
                // Not the stream working. Nothing is being shown to us, and the
                // supervisor should be free to act on the silence that follows.
                countersLock.lock()
                suspendedFrames += 1
                countersLock.unlock()
            default:
                // .idle, .blank, .started — the stream is alive and has nothing
                // to add. Proof of life, and the reason a still desktop no
                // longer reads as a fault.
                countersLock.lock()
                idleFrames += 1
                heartbeat += 1
                countersLock.unlock()
            }
            return
        }

        countersLock.lock()
        heartbeat += 1
        countersLock.unlock()
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
