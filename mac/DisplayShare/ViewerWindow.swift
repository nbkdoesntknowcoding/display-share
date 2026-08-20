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

    /// Where captured input goes. Weak: the model owns it.
    weak var forwarder: InputForwarder?
    /// The stream's pixel dimensions, needed to undo the letterboxing.
    private var videoSize = CGSize.zero
    private var lastModifiers = NSEvent.ModifierFlags()

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

    // MARK: - Input capture (Task 8.3)

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // inVisibleRect keeps the area correct across window resizes without
        // rebuilding it by hand.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                owner: self
            )
        )
    }

    /// Maps a pointer position to 0-1 within the VIDEO rectangle.
    ///
    /// The layer fills the view but the picture inside it is fitted with
    /// resizeAspect, so the drawn rect is centred with bars on one axis. Returns
    /// nil over a bar rather than clamping, which would stick the Windows cursor
    /// to the edge.
    private func normalise(_ event: NSEvent) -> (x: Double, y: Double)? {
        guard videoSize.width > 0, videoSize.height > 0,
            bounds.width > 0, bounds.height > 0
        else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let drawn = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let offsetX = (bounds.width - drawn.width) / 2
        let offsetY = (bounds.height - drawn.height) / 2
        let x = (point.x - offsetX) / drawn.width
        // AppKit measures y from the BOTTOM; the wire format measures from the
        // top. Forgetting this flips the pointer vertically.
        let y = 1 - (point.y - offsetY) / drawn.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (Double(x), Double(y))
    }

    private func sendMove(_ event: NSEvent) {
        guard let point = normalise(event) else { return }
        forwarder?.move(x: point.x, y: point.y)
    }

    override func mouseMoved(with event: NSEvent) { sendMove(event) }
    override func mouseDragged(with event: NSEvent) { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Position travels with the press so a click never lands wherever the
        // last move happened to leave the cursor.
        sendMove(event)
        forwarder?.button(0, down: true)
    }
    override func mouseUp(with event: NSEvent) { forwarder?.button(0, down: false) }
    override func rightMouseDown(with event: NSEvent) {
        sendMove(event)
        forwarder?.button(2, down: true)
    }
    override func rightMouseUp(with event: NSEvent) { forwarder?.button(2, down: false) }
    override func otherMouseDown(with event: NSEvent) { forwarder?.button(1, down: true) }
    override func otherMouseUp(with event: NSEvent) { forwarder?.button(1, down: false) }

    override func scrollWheel(with event: NSEvent) {
        // Divided to line-ish units, matching what the receiver sends and what
        // the Windows side turns back into wheel notches.
        let divisor = event.hasPreciseScrollingDeltas ? 12.0 : 1.0
        forwarder?.scroll(dx: event.scrollingDeltaX / divisor, dy: event.scrollingDeltaY / divisor)
    }

    override func keyDown(with event: NSEvent) {
        guard let code = MacKeyCodes.code(for: event.keyCode) else { return }
        forwarder?.key(code: code, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let code = MacKeyCodes.code(for: event.keyCode) else { return }
        forwarder?.key(code: code, down: false)
    }

    /// Modifiers arrive as a changed flag set rather than as key events, so the
    /// press and release have to be derived by comparing against the last set.
    override func flagsChanged(with event: NSEvent) {
        let now = event.modifierFlags
        for (flag, code) in MacKeyCodes.modifierCodes {
            let wasDown = lastModifiers.contains(flag)
            let isDown = now.contains(flag)
            if wasDown != isDown { forwarder?.key(code: code, down: isDown) }
        }
        lastModifiers = now
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
        videoSize = CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )

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
        view.forwarder = model.forwarder
        model.surface = view
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {
        nsView.forwarder = model.forwarder
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
    /// Forwarding is OFF until asked for. Taking the keyboard the moment a
    /// window opens would be startling, and would swallow Cmd-W.
    @Published var inputEnabled = false
    private(set) lazy var forwarder: InputForwarder = {
        let forwarder = InputForwarder(send: { [weak self] text in self?.client.send(text) })
        forwarder.onEnabledChanged = { [weak self] enabled in
            self?.inputEnabled = enabled
        }
        return forwarder
    }()

    func setInputEnabled(_ enabled: Bool) {
        forwarder.isEnabled = enabled
        if enabled { surface?.window?.makeFirstResponder(surface) }
    }

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
                .accessibilityElement()
                .accessibilityLabel("Windows desktop")
                .accessibilityValue(
                    model.status.connected
                        ? "Connected, \(model.status.decoder.width) by \(model.status.decoder.height)"
                        : "Not connected"
                )

            if model.showHUD {
                hud
                    .padding(10)
            }

            if model.status.connected {
                // A strong capability, so its state is unmissable and its
                // release is stated rather than left to be discovered.
                VStack(spacing: 7) {
                    Button(model.inputEnabled ? "Stop controlling" : "Control this PC") {
                        // Animated so the badge arrives rather than blinks into
                        // place; the state change is what the motion explains.
                        withAnimation(.easeOut(duration: 0.2)) {
                            model.setInputEnabled(!model.inputEnabled)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel(
                        model.inputEnabled
                            ? "Stop controlling this PC" : "Control this PC"
                    )
                    .accessibilityHint(
                        "Sends this Mac's keyboard and mouse to the Windows machine"
                    )

                    if model.inputEnabled {
                        Text("Your keyboard and mouse are driving Windows")
                            .accessibilityAddTraits(.updatesFrequently)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(Color.green, in: Capsule())
                            .foregroundStyle(.black)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, 10)
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
            // Releases anything still held before the socket goes: a modifier
            // left down on Windows has no event coming to clear it.
            model.setInputEnabled(false)
            model.stopDiscovery()
            model.disconnect()
        }
    }

    /// The acceptance for this task is a measured frame rate and a visible
    /// decode path, so the HUD is a requirement rather than a nicety.
    private var hud: some View {
        // Label/value rows on a native material rather than a monospace slab on
        // black: it reads at a glance mid-session, and matches the receiver so
        // the two apps look like one product.
        VStack(alignment: .leading, spacing: 3) {
            hudRow("fps", String(format: "%.0f", model.status.fps), lead: true)
            hudRow("size", "\(model.status.decoder.width)×\(model.status.decoder.height)")
            hudRow("decode", String(format: "%.1f ms", model.status.decoder.meanDecodeMs))
            hudRow("bitrate", String(format: "%.0f kbps", model.status.kilobitsPerSecond))
            hudRow("path", model.status.decoder.decodePath)
            if model.status.decoder.decodeFailures > 0 {
                hudRow("errors", "\(model.status.decoder.decodeFailures)", warn: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
        // One summarised label instead of every row read separately, which is
        // what VoiceOver does with a grid of numbers that updates each second.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stream statistics")
        .accessibilityValue(
            String(
                format: "%.0f frames per second, %d by %d, %.1f millisecond decode",
                model.status.fps,
                model.status.decoder.width,
                model.status.decoder.height,
                model.status.decoder.meanDecodeMs
            )
        )
    }

    private func hudRow(
        _ label: String, _ value: String, lead: Bool = false, warn: Bool = false
    ) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                // Tabular figures so the numbers stop twitching as they change.
                .font(.system(size: lead ? 12.5 : 11, weight: lead ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(warn ? Color.orange : Color.primary)
        }
        .frame(minWidth: 132, alignment: .leading)
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
