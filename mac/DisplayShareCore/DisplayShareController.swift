import AppKit
import Combine
import Foundation

/// Observable façade the SwiftUI menu bar drives.
///
/// Owns the helper lifecycle and keeps the UI honest about what is actually
/// running — including the case where the app re-attached to a display that
/// outlived a previous crash.
@MainActor
public final class DisplayShareController: ObservableObject {

    public enum State: Equatable {
        case idle
        case starting
        case active(displayID: UInt32)
        case failed(String)

        public var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var configuration = DisplayConfiguration()
    /// True when we adopted a display held by a helper that survived a crash.
    @Published public private(set) var reattached = false

    /// LAN URL to open on the receiver. nil until the stream is up.
    @Published public private(set) var streamURL: String?
    /// Drives the actionable "grant permission" affordance in the menu.
    @Published public private(set) var needsScreenRecordingPermission = false

    private let client: HelperClient
    private let pipeline: StreamPipeline
    private let port: UInt16

    public init(
        client: HelperClient = HelperClient(),
        port: UInt16 = 8787,
        codec: StreamPipeline.Codec = .h264
    ) {
        self.client = client
        self.port = port
        self.pipeline = StreamPipeline(codec: codec)
        // Task 3.3: size the virtual display to the receiver's actual panel so
        // the image is neither letterboxed nor stretched.
        self.pipeline.onReceiverPanel = { [weak self] panel in
            Task { @MainActor in self?.adoptReceiverPanel(panel) }
        }
        self.client.onDisplayTerminated = { [weak self] in
            Task { @MainActor in self?.state = .failed("macOS removed the display") }
        }
        self.client.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.state.isActive else { return }
                self.state = .failed("Lost connection to vd_helper")
            }
        }
    }

    public func start() {
        guard !state.isActive else { return }
        state = .starting
        do {
            try client.connect()
            // If a helper is already holding our display, this is a re-attach.
            let existing = try? client.status()
            let hadDisplay = existing?.displayID != nil
            let displayID = try client.createDisplay(configuration)
            reattached = hadDisplay
            // Capture + encode + serve. The display exists regardless of whether
            // streaming succeeds, so surface those failures separately.
            try pipeline.start(displayID: displayID, fps: Int(configuration.refreshRate))
            streamURL = "http://\(Self.primaryIPv4Address() ?? "localhost"):\(port)"
            state = .active(displayID: displayID)
        } catch let error as CaptureSession.CaptureError {
            FileHandle.standardError.write(Data("[DisplayShare] capture failed: \(error)\n".utf8))
            // The display itself is fine; only capture failed. Keep the URL so
            // the user can still reach the page, and say what to do about it.
            streamURL = "http://\(Self.primaryIPv4Address() ?? "localhost"):\(port)"
            state = .failed(error.description)
            needsScreenRecordingPermission = (error == .permissionDenied)
        } catch {
            FileHandle.standardError.write(Data("[DisplayShare] start failed: \(error)\n".utf8))
            state = .failed("\(error)")
        }
    }

    /// Opens the exact System Settings pane, rather than making the user hunt.
    public func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    public func stop() {
        pipeline.stop()
        pipeline.stopServers()
        streamURL = nil
        client.shutdown()
        reattached = false
        state = .idle
    }

    /// Live resolution / refresh change.
    ///
    /// The helper applies the mode to the EXISTING display rather than
    /// destroying and recreating it, so macOS keeps the user's windows where
    /// they were. Only the capture stream is rebuilt, and the HTTP server is
    /// left running so connected viewers are not dropped.
    public func update(configuration new: DisplayConfiguration) {
        let previous = configuration
        configuration = new
        guard state.isActive else { return }
        do {
            let displayID = try client.applyMode(new)
            if new.width != previous.width || new.height != previous.height
                || new.refreshRate != previous.refreshRate
            {
                try pipeline.reconfigureCapture(displayID: displayID, fps: Int(new.refreshRate))
            }
            state = .active(displayID: displayID)
        } catch {
            FileHandle.standardError.write(Data("[DisplayShare] reconfigure failed: \(error)\n".utf8))
            state = .failed("\(error)")
        }
    }

    /// True when the sender should follow whatever panel the receiver reports.
    @Published public var matchReceiver = true
    /// Last panel the receiver told us about, for display in the UI.
    @Published public private(set) var receiverPanel: ReceiverPanel?

    /// Largest virtual-display geometry that macOS reliably adopts, preserving
    /// the receiver's aspect ratio.
    ///
    /// MEASURED on macOS 26.2: CGVirtualDisplay is unreliable above ~1920x1200.
    /// Requests are sometimes silently HALVED (2560x1080 -> 1280x540,
    /// 1920x1440 -> 960x720) and sometimes fall back to 1920x1080
    /// (2560x1440, 3840x2160). applyMode still returns success, so the failure
    /// is invisible unless the result is read back.
    ///
    /// Rather than letterbox or stretch, fit the receiver's ASPECT RATIO inside
    /// the reliable envelope: a 2560x1080 (21:9) panel becomes 1920x810, which
    /// is verified working and fills the receiver exactly. The receiver upscales,
    /// which costs sharpness but never geometry.
    static func supportedGeometry(for panel: ReceiverPanel) -> (width: UInt32, height: UInt32) {
        let maxWidth: Double = 1920
        let maxHeight: Double = 1200
        let w = Double(max(panel.width, 1))
        let h = Double(max(panel.height, 1))

        let scale = min(1.0, min(maxWidth / w, maxHeight / h))
        // Even dimensions: H.264 chroma is subsampled 2x2, so odd sizes force
        // the encoder to pad and can shift colour by half a pixel.
        var width = UInt32((w * scale).rounded(.down)) & ~1
        var height = UInt32((h * scale).rounded(.down)) & ~1
        width = max(320, width)
        height = max(240, height)
        return (width, height)
    }

    private func adoptReceiverPanel(_ panel: ReceiverPanel) {
        FileHandle.standardError.write(Data(
            "[DisplayShare] receiver panel: \(panel.width)x\(panel.height) @\(panel.scale)x \(panel.refreshRate)Hz (matchReceiver=\(matchReceiver))\n".utf8))
        receiverPanel = panel
        guard matchReceiver else { return }

        let (width, height) = Self.supportedGeometry(for: panel)
        if width != panel.width || height != panel.height {
            FileHandle.standardError.write(Data(
                "[DisplayShare] panel \(panel.width)x\(panel.height) exceeds the reliable virtual-display envelope; using \(width)x\(height) at the same aspect ratio\n".utf8))
        }
        guard width != configuration.width || height != configuration.height else { return }

        var next = configuration
        next.width = width
        next.height = height
        update(configuration: next)
    }

    public func setResolution(width: UInt32, height: UInt32) {
        // An explicit choice overrides automatic matching until re-enabled.
        matchReceiver = false
        var next = configuration
        next.width = width
        next.height = height
        update(configuration: next)
    }

    public func setFrameRate(_ fps: Int) {
        var next = configuration
        next.refreshRate = Double(fps)
        update(configuration: next)
    }

    /// JPEG quality is a pure encoder setting — it needs no display or stream
    /// restart, so it can move under the user's finger.
    public var jpegQuality: Double {
        get { pipeline.quality }
        set { pipeline.quality = newValue; objectWillChange.send() }
    }

    /// Called from applicationWillTerminate so a clean quit never leaves a display.
    public func shutdownForQuit() {
        pipeline.stop()
        pipeline.stopServers()
        client.shutdown()
    }

    public var statistics: MJPEGServer.Statistics { pipeline.httpServer.statistics }
    public var socketStatistics: WebSocketServer.Statistics { pipeline.socketServer.statistics }

    /// Best-effort LAN address so the menu can show a URL the receiver can open.
    static func primaryIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidate: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard ptr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            // Prefer Ethernet/Wi-Fi over virtual interfaces.
            if name.hasPrefix("en") { return address }
            if candidate == nil { candidate = address }
        }
        return candidate
    }
}
