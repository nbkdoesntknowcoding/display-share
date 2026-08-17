import Foundation
import Network

/// WebSocket transport implementing protocol/SPEC.md v1.
///
/// Binary messages carry video access units; text messages carry the JSON
/// control channel. Built on NWProtocolWebSocket so the handshake, ping/pong,
/// fragmentation and close handshake are handled by the OS rather than by us.
public final class WebSocketServer: @unchecked Sendable {

    public struct Statistics: Sendable {
        public var connected: Bool = false
        public var rejectedConnections: Int = 0
        public var framesSent: Int = 0
        public var keyframesSent: Int = 0
        public var bytesSent: Int = 0
        public var sentFPS: Double = 0
        public var megabitsPerSecond: Double = 0
        /// Round trip measured from the receiver echoing our own timestamp back.
        public var roundTripMillis: Double = 0
        public var receiverDecodeMillis: Double = 0
        public var receiverDroppedFrames: Int = 0
    }

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "in.theboringpeople.displayshare.ws")

    private let lock = NSLock()
    private var client: NWConnection?
    private var stats = Statistics()

    private var windowStart = CFAbsoluteTimeGetCurrent()
    private var windowFrames = 0
    private var windowBytes = 0

    public private(set) var isRunning = false

    /// Raised when a receiver completes the `hello` handshake. The pipeline uses
    /// this to force an IDR so the client can decode from its very first frame.
    public var onClientReady: ((ReceiverPanel?) -> Void)?
    public var onKeyframeRequested: (() -> Void)?
    public var onResizeRequested: ((Int, Int) -> Void)?
    public var onClientDisconnected: (() -> Void)?

    /// Current encoded format, reported in `welcome`.
    public var videoFormat: VideoFormat?

    public init(port: UInt16 = 8788) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    public var hasClient: Bool {
        lock.lock(); defer { lock.unlock() }
        return client != nil
    }

    // MARK: - Lifecycle

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        isRunning = true
    }

    public func stop() {
        isRunning = false
        listener?.cancel()
        listener = nil
        lock.lock()
        let current = client
        client = nil
        stats.connected = false
        lock.unlock()
        current?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let alreadyBusy = client != nil
        if alreadyBusy {
            stats.rejectedConnections += 1
        } else {
            client = connection
            stats.connected = true
        }
        lock.unlock()

        connection.start(queue: queue)

        if alreadyBusy {
            // SPEC §4.7: exactly one receiver. Say why, then close — a silent
            // drop is indistinguishable from a network fault.
            send(
                control: .error(code: "busy", message: "another receiver is already connected"),
                on: connection)
            queue.asyncAfter(deadline: .now() + 0.2) { connection.cancel() }
            return
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.handleDisconnect(connection)
            default:
                break
            }
        }
        receive(on: connection)
    }

    private func handleDisconnect(_ connection: NWConnection) {
        lock.lock()
        guard client === connection else {
            lock.unlock()
            return
        }
        client = nil
        stats.connected = false
        lock.unlock()
        onClientDisconnected?()
    }

    // MARK: - Receiving

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                self.handleDisconnect(connection)
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            {
                switch metadata.opcode {
                case .text:
                    if let data { self.handleControl(data, on: connection) }
                case .close:
                    self.handleDisconnect(connection)
                    return
                default:
                    break
                }
            }
            self.receive(on: connection)
        }
    }

    private func handleControl(_ data: Data, on connection: NWConnection) {
        guard let message = try? JSONDecoder().decode(ControlMessage.self, from: data) else { return }

        switch message.type {
        case "hello":
            // SPEC §2: version mismatch is refused rather than guessed at.
            if let version = message.protocolVersion, version != WireProtocol.version {
                send(
                    control: .error(
                        code: "unsupported_version",
                        message: "sender speaks v\(WireProtocol.version), client sent v\(version)"),
                    on: connection)
                queue.asyncAfter(deadline: .now() + 0.2) { connection.cancel() }
                return
            }
            if let format = videoFormat {
                send(control: .welcome(video: format, sender: "display-share-mac/0.1.0"), on: connection)
            }
            onClientReady?(message.receiver)

        case "request_keyframe":
            onKeyframeRequested?()

        case "resize":
            if let w = message.width, let h = message.height { onResizeRequested?(w, h) }

        case "stats":
            lock.lock()
            stats.receiverDecodeMillis = message.decodeMillis ?? stats.receiverDecodeMillis
            stats.receiverDroppedFrames = message.droppedFrames ?? stats.receiverDroppedFrames
            // The receiver echoes back a timestamp we minted, so this is a true
            // round trip measured entirely against our own clock.
            if let echoed = message.lastTimestamp {
                let now = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000)
                if now > echoed { stats.roundTripMillis = Double(now - echoed) / 1000.0 }
            }
            lock.unlock()

        default:
            // SPEC §4: unknown types are ignored so either side can add
            // messages without a version bump.
            break
        }
    }

    // MARK: - Sending

    public func send(control message: ControlMessage) {
        lock.lock(); let current = client; lock.unlock()
        guard let current else { return }
        send(control: message, on: current)
    }

    private func send(control message: ControlMessage, on connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "control", metadata: [metadata])
        connection.send(
            content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Sends one encoded access unit. Uses `.idempotent` so a slow receiver
    /// cannot apply back-pressure to the encoder thread — shed frames rather
    /// than accumulate latency.
    public func send(video message: WireProtocol.VideoMessage) {
        lock.lock(); let current = client; lock.unlock()
        guard let current else { return }

        let framed = WireProtocol.encode(message)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "video", metadata: [metadata])
        current.send(
            content: framed, contentContext: context, isComplete: true, completion: .idempotent)

        lock.lock()
        stats.framesSent += 1
        if message.isKeyframe { stats.keyframesSent += 1 }
        stats.bytesSent += framed.count
        windowFrames += 1
        windowBytes += framed.count
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - windowStart
        if elapsed >= 1.0 {
            stats.sentFPS = Double(windowFrames) / elapsed
            stats.megabitsPerSecond = Double(windowBytes) * 8.0 / elapsed / 1_000_000.0
            windowStart = now
            windowFrames = 0
            windowBytes = 0
        }
        lock.unlock()
    }
}
