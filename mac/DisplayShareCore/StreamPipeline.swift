import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Capture → encode → transmit.
///
/// Draining, encoding and sending all happen on a worker thread. They must
/// never run inside the ScreenCaptureKit callback: Phase 0 measured that doing
/// encode work there costs more than half the frame rate.
public final class StreamPipeline: @unchecked Sendable {

    public enum Codec: String, Sendable {
        /// Phase 1 fallback. Zero client code, roughly 4x the bandwidth.
        case mjpeg
        /// Phase 2 default: hardware H.264 over WebSocket.
        case h264
    }

    public private(set) var capture: CaptureSession?
    public let httpServer: MJPEGServer
    public let socketServer: WebSocketServer
    public let jpegEncoder: JPEGEncoder
    public let h264Encoder: H264Encoder
    public private(set) var codec: Codec

    private var worker: Thread?
    private var running = false
    private let lock = NSLock()

    private var captureWindowStart = CFAbsoluteTimeGetCurrent()
    private var captureWindowFrames = 0
    private var measuredCaptureFPS: Double = 0
    private var frameIndex: Int64 = 0
    private var currentFPS = 60

    public init(
        httpServer: MJPEGServer = MJPEGServer(),
        socketServer: WebSocketServer = WebSocketServer(),
        jpegEncoder: JPEGEncoder = JPEGEncoder(),
        h264Encoder: H264Encoder = H264Encoder(),
        codec: Codec = .h264
    ) {
        self.httpServer = httpServer
        self.socketServer = socketServer
        self.jpegEncoder = jpegEncoder
        self.h264Encoder = h264Encoder
        self.codec = codec

        // A receiver that just completed `hello` needs an IDR immediately;
        // otherwise it stares at nothing until the next natural keyframe.
        self.socketServer.onClientReady = { [weak self] _ in
            self?.h264Encoder.requestKeyframe()
        }
        self.socketServer.onKeyframeRequested = { [weak self] in
            self?.h264Encoder.requestKeyframe()
        }
        self.h264Encoder.onEncodedFrame = { [weak self] frame in
            guard let self else { return }
            let timestamp = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000)
            self.socketServer.send(
                video: .init(
                    isKeyframe: frame.isKeyframe,
                    timestampMicros: timestamp,
                    payload: frame.data))
        }
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// H.264 wants NV12 natively; BGRA would force a colour conversion on every
    /// frame. JPEG is happy with either, since CIImage handles both.
    private var pixelFormat: OSType {
        codec == .h264 ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
    }

    public func start(displayID: CGDirectDisplayID, fps: Int) throws {
        stop()
        currentFPS = fps

        // Servers start BEFORE capture so a permission failure is visibly
        // different from an unreachable machine.
        if !httpServer.isRunning { try httpServer.start() }
        if !socketServer.isRunning { try socketServer.start() }

        let session = CaptureSession(
            configuration: .init(displayID: displayID, fps: fps, pixelFormat: pixelFormat))
        try session.start()

        if codec == .h264 {
            try h264Encoder.start(
                width: Int32(session.pixelSize.width), height: Int32(session.pixelSize.height), fps: fps)
            socketServer.videoFormat = VideoFormat(
                width: Int(session.pixelSize.width), height: Int(session.pixelSize.height), fps: fps)
            h264Encoder.requestKeyframe()
        }

        lock.lock()
        capture = session
        running = true
        lock.unlock()

        spawnWorker(session)
    }

    private func spawnWorker(_ session: CaptureSession) {
        let thread = Thread { [weak self] in self?.drain(session) }
        thread.name = "DisplayShare.encode"
        // Encoding competes with capture; responsive, but not above it.
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

            // Publish capture stats even with nobody watching, so the HUD can
            // distinguish "no viewer" from "no frames arriving".
            httpServer.updateCaptureStats(
                captureFPS: measuredCaptureFPS,
                dropped: session.frames.statistics.droppedOldest)

            switch codec {
            case .h264:
                // Encode only when a receiver is attached — no point burning
                // CPU on frames that go nowhere.
                guard socketServer.hasClient else { continue }
                let pts = CMTime(value: frameIndex, timescale: CMTimeScale(currentFPS))
                frameIndex += 1
                try? h264Encoder.encode(frame, presentationTime: pts)

            case .mjpeg:
                guard httpServer.statistics.connectedClients > 0 else { continue }
                guard let jpeg = jpegEncoder.encode(frame) else { continue }
                httpServer.broadcast(
                    jpeg: jpeg,
                    encodeMillis: jpegEncoder.lastEncodeSeconds * 1000,
                    captureFPS: measuredCaptureFPS,
                    dropped: session.frames.statistics.droppedOldest)
            }
        }
    }

    public func updateFrameRate(_ fps: Int) {
        currentFPS = fps
        lock.lock(); let session = capture; lock.unlock()
        session?.updateFrameRate(fps)
    }

    /// Rebuilds capture and encoder for a new geometry WITHOUT touching the
    /// servers, so a connected receiver stays connected across a resolution
    /// change. The virtual display itself is never destroyed.
    public func reconfigureCapture(displayID: CGDirectDisplayID, fps: Int) throws {
        lock.lock()
        running = false
        let old = capture
        capture = nil
        lock.unlock()
        old?.stop()
        h264Encoder.stop()

        currentFPS = fps
        let session = CaptureSession(
            configuration: .init(displayID: displayID, fps: fps, pixelFormat: pixelFormat))
        try session.start()

        if codec == .h264 {
            try h264Encoder.start(
                width: Int32(session.pixelSize.width), height: Int32(session.pixelSize.height), fps: fps)
            let format = VideoFormat(
                width: Int(session.pixelSize.width), height: Int(session.pixelSize.height), fps: fps)
            socketServer.videoFormat = format
            // SPEC §4.4: tell the receiver to reconfigure, then send a keyframe.
            socketServer.send(control: .videoFormat(format))
            h264Encoder.requestKeyframe()
        }

        lock.lock()
        capture = session
        running = true
        lock.unlock()
        spawnWorker(session)
    }

    public var quality: Double {
        get { jpegEncoder.quality }
        set { jpegEncoder.quality = newValue }
    }

    public func setBitrate(_ bitrate: Int) {
        h264Encoder.setBitrate(bitrate)
    }

    public func stop() {
        lock.lock()
        running = false
        let session = capture
        capture = nil
        lock.unlock()

        session?.stop()
        h264Encoder.stop()
        worker = nil
    }

    public func stopServers() {
        httpServer.stop()
        socketServer.stop()
    }
}
