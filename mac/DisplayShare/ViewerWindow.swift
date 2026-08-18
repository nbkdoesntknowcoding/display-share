import AVFoundation
import CoreMedia
import CoreVideo
import DisplayShareCore
import Network
import SwiftUI

/// The Mac viewing a Windows desktop (Task 8.2).
///
/// This is a second ROLE inside the existing app, not a second app. Shipping a
/// separate viewer binary was considered and rejected: two apps with nearly
/// identical names already caused real confusion here, when the receiver was
/// opened on the Mac and appeared to do nothing.

// MARK: - Display surface

/// Hosts an `AVSampleBufferDisplayLayer` and feeds it decoded frames.
final class VideoLayerView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // No implicit animation: the layer would otherwise slide into place on
        // every window resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func display(_ imageBuffer: CVImageBuffer) {
        // The format description is derived from the buffer and cached: building
        // one per frame is pure overhead, and it only changes when the sender's
        // resolution does.
        if formatDescription == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: imageBuffer)
        {
            var created: CMVideoFormatDescription?
            guard
                CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: imageBuffer,
                    formatDescriptionOut: &created
                ) == noErr
            else { return }
            formatDescription = created
        }
        guard let formatDescription else { return }

        // This is a live desktop, not playback: the newest frame should appear
        // the instant it decodes. An invalid presentation timestamp does NOT
        // express that — with no timebase to schedule against, the layer simply
        // holds every frame and renders nothing, which looks exactly like a
        // decode failure from the outside. The DisplayImmediately attachment
        // set below is what actually asks for it.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ) == noErr,
            let sampleBuffer
        else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        // A failed layer stays failed until flushed, so a single bad frame
        // would otherwise end the session with no error shown anywhere.
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }
}

struct VideoSurface: NSViewRepresentable {
    let model: ViewerModel

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        model.surface = view
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {
        model.surface = nsView
    }
}

// MARK: - Model

@MainActor
final class ViewerModel: ObservableObject {
    @Published var status = ViewerClient.Status()
    @Published var discovered: [DiscoveredSender] = []
    @Published var host = ""
    @Published var port = String(ViewerModel.defaultPort)
    @Published var showHUD = true

    /// The reverse direction's default port. Separate from the Mac sender's
    /// 8787/8788 so one machine can hold both roles without a clash.
    static let defaultPort = 7879

    struct DiscoveredSender: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    weak var surface: VideoLayerView?

    private let client = ViewerClient()
    private var browser: NWBrowser?

    init() {
        client.onFrame = { [weak self] buffer in
            self?.surface?.display(buffer)
        }
        client.onStatus = { [weak self] status in
            self?.status = status
        }
    }

    func connect() {
        guard let portNumber = Int(port), (1...65535).contains(portNumber) else {
            status.message = "Port must be between 1 and 65535"
            return
        }
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            status.message = "Enter the Windows machine's address"
            return
        }
        client.connect(host: target, port: portNumber)
    }

    func connect(to sender: DiscoveredSender) {
        // Resolve the Bonjour endpoint to an address before connecting:
        // URLSessionWebSocketTask takes a URL, not an NWEndpoint.
        let connection = NWConnection(to: sender.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            guard case .hostPort(let resolvedHost, let resolvedPort) = connection.currentPath?.remoteEndpoint
            else { return }
            var text = "\(resolvedHost)"
            // Strip the IPv6 zone suffix: it is meaningful to the interface but
            // not valid inside a URL.
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            connection.cancel()
            Task { @MainActor in
                self?.host = text
                self?.port = String(resolvedPort.rawValue)
                self?.client.connect(host: text, port: Int(resolvedPort.rawValue))
            }
        }
        connection.start(queue: .global())
    }

    func disconnect() {
        client.disconnect()
    }

    /// Browses for Windows senders.
    ///
    /// A distinct service type, NOT the `_displayshare._tcp` the Mac sender
    /// advertises. Sharing one type would make the Windows receiver list other
    /// Windows machines as senders, and the Mac list itself.
    func startDiscovery() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_dsreverse._tcp", domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let senders = results.compactMap { result -> DiscoveredSender? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredSender(id: name, name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                self?.discovered = senders.sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }
}

// MARK: - View

struct ViewerView: View {
    /// Watched so the viewer can refuse to run while this Mac is sending. Both
    /// directions at once between the same pair of machines is a feedback loop:
    /// each side encodes the other's picture, the link saturates, and the
    /// adaptive bitrate controller reacts to congestion it is itself creating.
    @ObservedObject var controller: DisplayShareController
    @StateObject private var model = ViewerModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoSurface(model: model)
                .frame(minWidth: 640, minHeight: 360)

            if model.showHUD {
                hud
                    .padding(10)
            }

            if !model.status.connected {
                Group {
                    if controller.state.isActive {
                        sendingInsteadPanel
                    } else {
                        connectPanel
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.75))
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { model.startDiscovery() }
        .onDisappear {
            model.stopDiscovery()
            model.disconnect()
        }
    }

    /// The acceptance for this task is a measured frame rate and a visible
    /// decode path, so the HUD is a requirement rather than a nicety.
    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.0f fps", model.status.fps))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Text("\(model.status.decoder.width)×\(model.status.decoder.height)")
            Text(model.status.decoder.decodePath)
            Text(String(format: "%.0f kbps · %.1f ms decode",
                        model.status.kilobitsPerSecond,
                        model.status.decoder.meanDecodeMs))
            if model.status.decoder.decodeFailures > 0 {
                Text("\(model.status.decoder.decodeFailures) decode failures")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Shown instead of the connect controls while this Mac is sending.
    ///
    /// Offers a Stop button rather than just refusing: the user asked to view
    /// something, and making them hunt through the menu bar to find out why they
    /// cannot is worse than doing the obvious thing for them on request.
    private var sendingInsteadPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("This Mac is sending its screen")
                .font(.title3.bold())
            Text("Running both directions at once between the same two machines feeds each screen back into the other. Stop sending first, then connect.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Stop sending and view instead") { controller.stop() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
    }

    private var connectPanel: some View {
        VStack(spacing: 14) {
            Text("View a Windows PC")
                .font(.title2.bold())
            Text("Run Display Share on the Windows machine and choose “Share this PC’s screen”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !model.discovered.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Found on this network").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.discovered) { sender in
                        Button {
                            model.connect(to: sender)
                        } label: {
                            Label(sender.name, systemImage: "display")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: 360)
            }

            HStack {
                TextField("Windows address", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                TextField("Port", text: $model.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Button("Connect") { model.connect() }
                    .keyboardShortcut(.defaultAction)
            }

            Text(model.status.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }
}
