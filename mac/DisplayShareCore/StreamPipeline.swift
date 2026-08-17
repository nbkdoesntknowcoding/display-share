import CoreGraphics
import Foundation

/// Drains the capture queue, encodes, and broadcasts — on its own thread.
///
/// This is the consumer side of the Task 1.2 contract. It must never run inside
/// the ScreenCaptureKit callback: Phase 0 measured that doing encode work there
/// costs more than half the frame rate.
public final class StreamPipeline: @unchecked Sendable {

    public private(set) var capture: CaptureSession?
    public let server: MJPEGServer
    public let encoder: JPEGEncoder

    private var worker: Thread?
    private var running = false
    private let lock = NSLock()

    private var captureWindowStart = CFAbsoluteTimeGetCurrent()
    private var captureWindowFrames = 0
    private var measuredCaptureFPS: Double = 0

    public init(server: MJPEGServer = MJPEGServer(), encoder: JPEGEncoder = JPEGEncoder()) {
        self.server = server
        self.encoder = encoder
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func start(displayID: CGDirectDisplayID, fps: Int) throws {
        stop()

        // Start the server FIRST so the viewer page and HUD stay reachable even
        // when capture cannot start — otherwise a permission problem looks
        // identical to the machine being unreachable.
        if !server.isRunning { try server.start() }

        let session = CaptureSession(configuration: .init(displayID: displayID, fps: fps))
        try session.start()

        lock.lock()
        capture = session
        running = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.drain(session) }
        thread.name = "DisplayShare.encode"
        // Encoding competes with capture; keep it responsive but not above it.
        thread.qualityOfService = .userInitiated
        thread.start()
        worker = thread
    }

    private func drain(_ session: CaptureSession) {
        while isRunning {
            guard let frame = session.frames.dequeue(timeout: 0.5) else { continue }

            captureWindowFrames += 1
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - captureWindowStart
            if elapsed >= 1.0 {
                measuredCaptureFPS = Double(captureWindowFrames) / elapsed
                captureWindowStart = now
                captureWindowFrames = 0
            }

            // Publish capture stats even with nobody watching, so the HUD and
            // logs can distinguish "no viewer" from "no frames arriving".
            server.updateCaptureStats(
                captureFPS: measuredCaptureFPS,
                dropped: session.frames.statistics.droppedOldest)

            // Skip the encode entirely when nobody is watching — no point
            // burning CPU on frames that go nowhere.
            guard server.statistics.connectedClients > 0 else { continue }
            guard let jpeg = encoder.encode(frame) else { continue }

            server.broadcast(
                jpeg: jpeg,
                encodeMillis: encoder.lastEncodeSeconds * 1000,
                captureFPS: measuredCaptureFPS,
                dropped: session.frames.statistics.droppedOldest)
        }
    }

    public func updateFrameRate(_ fps: Int) {
        lock.lock(); let session = capture; lock.unlock()
        session?.updateFrameRate(fps)
    }

    /// Rebuilds the capture stream for a new display geometry WITHOUT touching
    /// the server, so connected viewers stay connected across a resolution
    /// change. The virtual display itself is never destroyed (the helper applies
    /// the mode in place), so the user's window arrangement survives.
    public func reconfigureCapture(displayID: CGDirectDisplayID, fps: Int) throws {
        lock.lock()
        running = false
        let old = capture
        capture = nil
        lock.unlock()
        old?.stop()

        let session = CaptureSession(configuration: .init(displayID: displayID, fps: fps))
        try session.start()

        lock.lock()
        capture = session
        running = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.drain(session) }
        thread.name = "DisplayShare.encode"
        thread.qualityOfService = .userInitiated
        thread.start()
        worker = thread
    }

    public var quality: Double {
        get { encoder.quality }
        set { encoder.quality = newValue }
    }

    public func stop() {
        lock.lock()
        running = false
        let session = capture
        capture = nil
        lock.unlock()

        session?.stop()
        worker = nil
    }

    public func stopServer() {
        server.stop()
    }
}
