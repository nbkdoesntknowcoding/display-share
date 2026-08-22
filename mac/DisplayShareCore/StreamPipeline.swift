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

    /// Task 3.3: the receiver's panel geometry, reported in `hello`. The
    /// controller decides whether to adopt it.
    public var onReceiverPanel: ((ReceiverPanel) -> Void)?
    /// SCStream died on its own (display gone, permission revoked, post-wake).
    public var onCaptureStopped: ((Error) -> Void)?

    private var bitrate = AdaptiveBitrateController()
    private let bitrateLock = NSLock()

    /// Current adaptive target, for the HUD.
    public var targetBitrate: Int {
        bitrateLock.lock(); defer { bitrateLock.unlock() }
        return bitrate.currentBitrate
    }

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
        self.socketServer.onClientReady = { [weak self] panel in
            self?.h264Encoder.requestKeyframe()
            if let panel { self?.onReceiverPanel?(panel) }
        }
        self.socketServer.onKeyframeRequested = { [weak self] in
            self?.h264Encoder.requestKeyframe()
        }
        // A frame the send gate shed leaves the receiver decoding against a
        // reference it never got, and nothing over there can detect that — the
        // wire format has no sequence number, so its decoder does not
        // necessarily error, it just goes wrong and stays wrong until the next
        // natural keyframe two seconds later. The side that dropped the frame
        // is the only side that knows, so it repairs.
        self.socketServer.onKeyframeNeededAfterDrop = { [weak self] in
            self?.h264Encoder.requestKeyframe()
        }
        // Adaptive bitrate: degrade sharpness under congestion rather than let
        // latency accumulate. Queue depth is bounded elsewhere, so this only
        // ever changes quality.
        self.socketServer.onReceiverReport = { [weak self] rtt, dropRate in
            guard let self else { return }
            self.bitrateLock.lock()
            let decision = self.bitrate.ingest(
                .init(roundTripMillis: rtt, dropRate: dropRate, at: Date()))
            let target = self.bitrate.currentBitrate
            self.bitrateLock.unlock()

            switch decision {
            case .hold:
                break
            case .decrease, .increase:
                self.h264Encoder.setBitrate(target)
                FileHandle.standardError.write(Data(
                    String(format: "[DisplayShare] bitrate -> %.1f Mbps (rtt %.0fms, drops %.1f%%)\n",
                           Double(target) / 1e6, rtt, dropRate * 100).utf8))
            }
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

    /// Cumulative frames handed downstream since the pipeline started. Used by
    /// SessionSupervisor to tell "working" from "quietly dead".
    public var framesProcessed: Int {
        codec == .h264
            ? h264Encoder.statistics.framesEncoded
            : httpServer.statistics.framesSent
    }

    /// Rebuilds capture (and the encoder) for the display already in use,
    /// forcing a keyframe. Does NOT touch the virtual display or the servers, so
    /// window arrangement and any attached receiver survive.
    @discardableResult
    public func restartCapture() -> Bool {
        lock.lock()
        let session = capture
        let fps = currentFPS
        lock.unlock()
        guard let displayID = session?.configuration.displayID else { return false }
        do {
            try reconfigureCapture(displayID: displayID, fps: fps)
            return true
        } catch {
            FileHandle.standardError.write(
                Data("[DisplayShare] restartCapture failed: \(error)\n".utf8))
            return false
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
        session.onStreamStopped = { [weak self] error in self?.onCaptureStopped?(error) }
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
                // Encode only for an AUTHORISED receiver: an unpaired one must
                // get no video, and there is no point burning CPU either way.
                guard socketServer.hasAuthorisedClient else { continue }
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
        session.onStreamStopped = { [weak self] error in self?.onCaptureStopped?(error) }
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
