import CoreVideo
import Foundation

/// Connects the Mac to a Windows sender and decodes what arrives (Task 8.2).
///
/// The Mac app gains a second ROLE rather than a second app. Two binaries with
/// near-identical names already caused real confusion in this project — the user
/// opened the receiver on the Mac and could not tell why nothing happened — so
/// the reverse direction lives inside the app that is already installed.
///
/// Parsing is `WireProtocol`, unchanged and already covered by the golden
/// vectors, so the viewer inherits that coverage instead of growing a second
/// parser that can drift.
public final class ViewerClient: NSObject, @unchecked Sendable {

    public struct Status: Sendable, Equatable {
        public var connected = false
        public var message = "Not connected"
        /// Frames actually displayed per second, measured over a moving window.
        public var fps = 0.0
        public var kilobitsPerSecond = 0.0
        public var decoder = VideoDecoder.Stats()

        public init() {}
    }

    /// Called on the main queue with each decoded frame.
    public var onFrame: ((CVImageBuffer) -> Void)?
    /// Called on the main queue whenever the status changes.
    public var onStatus: ((Status) -> Void)?

    private let decoder = VideoDecoder()
    private let queue = DispatchQueue(label: "in.theboringpeople.displayshare.viewer")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var status = Status()

    /// Sliding one-second window, so the HUD reflects what is happening now
    /// rather than an average since connection that never recovers from a stall.
    private var windowStart = Date()
    private var windowFrames = 0
    private var windowBytes = 0

    public override init() { super.init() }

    public func connect(host: String, port: Int) {
        queue.async { [self] in
            disconnectLocked()

            // Bare IPv6 literals need brackets, and a Bonjour result on a
            // link-local address is exactly where that shows up.
            let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            guard let url = URL(string: "ws://\(hostPart):\(port)/") else {
                publish { $0.message = "Invalid address: \(host)" }
                return
            }

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: url)
            self.session = session
            self.task = task
            publish {
                $0.connected = false
                $0.message = "Connecting to \(host)…"
            }
            Self.trace("connect -> \(url.absoluteString)")
            task.resume()
            receiveNext()
        }
    }

    /// Sends a text message on the same socket (SPEC §4.10 input, §4 control).
    public func send(_ text: String) {
        queue.async { [self] in
            guard let task else { return }
            // Failures are dropped rather than surfaced: input is a stream of
            // disposable events, and one lost mouse move is not worth tearing
            // the session down or showing an error for.
            task.send(.string(text)) { _ in }
        }
    }

    public func disconnect() {
        queue.async { [self] in
            disconnectLocked()
            publish {
                $0 = Status()
                $0.message = "Disconnected"
            }
        }
    }

    private func disconnectLocked() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receiveNext() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    if case .data(let data) = message {
                        self.handle(data)
                    }
                    // Text on this socket is the control channel; the viewer
                    // does not need it yet, and ignoring it is better than
                    // dropping the connection over it.
                    self.receiveNext()
                case .failure(let error):
                    self.publish {
                        $0.connected = false
                        $0.message = "Connection lost: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func handle(_ data: Data) {
        if windowFrames < 3 { Self.trace("frame \(data.count) bytes") }
        let message: WireProtocol.VideoMessage
        do {
            message = try WireProtocol.decode(data)
        } catch {
            publish { $0.message = "Malformed frame: \(error)" }
            return
        }

        do {
            let image = try decoder.decode(message)
            if let image, Self.isTracing, windowFrames < 1 {
                // Mean luminance of what actually came out of the decoder. A
                // stream that decodes perfectly and renders black is impossible
                // to tell from one that never rendered, unless the pixels are
                // measured here.
                CVPixelBufferLockBaseAddress(image, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(image) {
                    let height = CVPixelBufferGetHeight(image)
                    let rowBytes = CVPixelBufferGetBytesPerRow(image)
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    var total = 0, count = 0, peak = 0
                    for y in stride(from: 0, to: height, by: 17) {
                        for x in stride(from: 0, to: rowBytes, by: 997) {
                            let v = Int(bytes[y * rowBytes + x])
                            total += v; count += 1; peak = max(peak, v)
                        }
                    }
                    Self.trace("decoded mean=\(count > 0 ? total / count : -1) peak=\(peak) size=\(CVPixelBufferGetWidth(image))x\(height)")
                }
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
            if let image {
                DispatchQueue.main.async { [weak self] in self?.onFrame?(image) }
            }
        } catch {
            publish { $0.message = "Decode failed: \(error)" }
            return
        }

        windowFrames += 1
        windowBytes += data.count
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1.0 {
            let fps = Double(windowFrames) / elapsed
            let kbps = Double(windowBytes) * 8 / 1000 / elapsed
            windowStart = Date()
            windowFrames = 0
            windowBytes = 0
            publish { [decoder] in
                $0.connected = true
                $0.message = "Connected"
                $0.fps = fps
                $0.kilobitsPerSecond = kbps
                $0.decoder = decoder.stats
            }
        } else if !status.connected {
            publish { [decoder] in
                $0.connected = true
                $0.message = "Connected"
                $0.decoder = decoder.stats
            }
        }
    }

    /// Set DS_VIEWER_TRACE=1 to log what the viewer actually receives.
    ///
    /// Kept rather than deleted: when the picture was black, no amount of
    /// reasoning distinguished "no frames arrived" from "frames arrived, decoded
    /// correctly, and were never drawn". Measuring the decoded pixels is what
    /// separated them, and it took one run.
    static let isTracing = ProcessInfo.processInfo.environment["DS_VIEWER_TRACE"] != nil

    static func trace(_ text: String) {
        guard isTracing else { return }
        let url = URL(fileURLWithPath: "/tmp/ds-viewer-trace.log")
        if let data = "\(Date()) \(text)\n".data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else { try? data.write(to: url) }
        }
    }

    private func publish(_ mutate: (inout Status) -> Void) {
        mutate(&status)
        let snapshot = status
        DispatchQueue.main.async { [weak self] in self?.onStatus?(snapshot) }
    }
}
