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
        /// Access units shed by the send gate because the socket had not yet
        /// taken the previous one. This is the number that must move when a
        /// link goes slow — if it stays at zero while latency climbs, the
        /// stream is buffering again.
        public var framesDropped: Int = 0
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
    /// True only after a completed handshake INCLUDING the pairing gate. Video
    /// is keyed off this, never off mere connectedness — otherwise the PIN would
    /// be advisory and an unpaired device would still receive the stream.
    private var authorised = false
    /// Guarded by `lock`. Bounds how far the encoder may run ahead of the
    /// socket; see SendGate for the policy and why it exists.
    private var gate = SendGate()
    private var stats = Statistics()
    /// Previous cumulative counters, so drop rate is measured per interval.
    private var previousDecodedFrames = 0
    private var previousDroppedFrames = 0

    private var windowStart = CFAbsoluteTimeGetCurrent()
    private var windowFrames = 0
    private var windowBytes = 0
    private var windowDropsAtStart = 0

    public private(set) var isRunning = false

    /// Raised when a receiver completes the `hello` handshake. The pipeline uses
    /// this to force an IDR so the client can decode from its very first frame.
    public var onClientReady: ((ReceiverPanel?) -> Void)?
    public var onKeyframeRequested: (() -> Void)?
    /// Raised when the send gate shed a frame, which breaks the receiver's
    /// reference chain. Nothing on the receiver can detect that — the wire
    /// format has no sequence number — so the pipeline answers with an IDR.
    public var onKeyframeNeededAfterDrop: (() -> Void)?
    public var onResizeRequested: ((Int, Int) -> Void)?
    public var onClientDisconnected: (() -> Void)?
    /// (roundTripMillis, dropRate) from each receiver `stats` message.
    public var onReceiverReport: ((Double, Double) -> Void)?
    /// A batch of forwarded input events from an authorised receiver.
    public var onInput: (([ForwardedInputEvent]) -> Void)?
    /// Fired on a completed handshake so per-session input state can be reset.
    public var onClientReadyForInput: (() -> Void)?

    /// Current encoded format, reported in `welcome`.
    public var videoFormat: VideoFormat?

    /// When set, receivers must be paired before they get video.
    public let pairing: PairingStore?

    public init(port: UInt16 = 8788, pairing: PairingStore? = nil) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.pairing = pairing
    }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// A socket is attached. NOT sufficient to send video.
    public var hasClient: Bool {
        lock.lock(); defer { lock.unlock() }
        return client != nil
    }

    /// The attached receiver has completed the handshake and is paired.
    public var hasAuthorisedClient: Bool {
        lock.lock(); defer { lock.unlock() }
        return client != nil && authorised
    }

    // MARK: - Lifecycle

    public func start() throws {
        // Nagle holds a small write back waiting for the previous ACK, while
        // the peer's delayed ACK holds that ACK back waiting for more data.
        // This socket carries the input channel — a stream of small mouse and
        // keyboard messages — so the two wait for each other and add the
        // classic ~40ms before a click lands. The receiver disables it too;
        // either end left on is enough to cause the stall.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        let listener = try NWListener(using: parameters, on: port)

        // Bonjour/mDNS advertisement (SPEC §4a). The TXT record carries enough
        // for the receiver to render a useful list before connecting.
        let hostName = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        listener.service = NWListener.Service(
            name: hostName,
            type: "_displayshare._tcp",
            domain: nil,
            txtRecord: NWTXTRecord([
                "v": String(WireProtocol.version),
                "name": hostName,
                "pair": pairing == nil ? "none" : "required",
            ]))

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
            authorised = false
            gate.reset()
            // A new receiver starts its counters from zero.
            previousDecodedFrames = 0
            previousDroppedFrames = 0
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
        authorised = false
        gate.reset()
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

    /// Hello held while the receiver pairs, so the handshake can resume.
    private var pendingHello: ControlMessage?

    private func completeHandshake(_ message: ControlMessage, on connection: NWConnection) {
        lock.lock()
        authorised = true
        lock.unlock()
        onClientReadyForInput?()
        if let format = videoFormat {
            send(control: .welcome(video: format, sender: "display-share-mac/0.1.0"), on: connection)
        }
        onClientReady?(message.receiver)
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data("[DisplayShare] \(text)\n".utf8))
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
            // Pairing gate (SPEC §4.9). An unpaired receiver is told exactly
            // what to do rather than silently getting no video.
            if let pairing {
                guard pairing.isAuthorised(deviceId: message.deviceId, token: message.token) else {
                    let pin = pairing.beginPairing()
                    log("receiver is not paired; PIN \(pin)")
                    send(
                        control: .error(
                            code: "pairing_required",
                            message: "Enter the PIN shown on the Mac to pair this device."),
                        on: connection)
                    pendingHello = message
                    return
                }
            }
            completeHandshake(message, on: connection)

        case "pair":
            guard let pairing else { return }
            guard let deviceId = message.deviceId, let pin = message.pin else {
                send(control: .error(code: "pair_rejected", message: "missing deviceId or pin"), on: connection)
                return
            }
            switch pairing.completePairing(
                deviceId: deviceId, deviceName: message.deviceName ?? "Unknown device", pin: pin)
            {
            case .paired(let token):
                log("paired \(message.deviceName ?? deviceId)")
                var paired = ControlMessage(type: "paired")
                paired.token = token
                paired.sender = ProcessInfo.processInfo.hostName
                    .replacingOccurrences(of: ".local", with: "")
                send(control: paired, on: connection)
                // The receiver is authorised now; resume the handshake it began.
                if let hello = pendingHello {
                    pendingHello = nil
                    completeHandshake(hello, on: connection)
                }
            case .wrongPIN:
                send(control: .error(code: "pair_rejected", message: "Incorrect PIN."), on: connection)
            case .rateLimited(let retryAfter):
                send(
                    control: .error(
                        code: "pair_rejected",
                        message: "Too many attempts. Try again in \(Int(retryAfter.rounded()))s."),
                    on: connection)
            case .noPairingInProgress:
                send(control: .error(code: "pair_rejected", message: "No pairing in progress."), on: connection)
            }

        case "input":
            // SPEC §4.10 safety: input is a far stronger capability than
            // viewing, so it is refused unless the receiver is authorised.
            // Checking here rather than downstream keeps the gate at the boundary.
            lock.lock()
            let allowed = client === connection && authorised
            lock.unlock()
            guard allowed else {
                log("ignoring input from an unauthorised receiver")
                return
            }
            if let events = message.events { onInput?(events) }

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
                if now > echoed {
                    let millis = Double(now - echoed) / 1000.0
                    // Sanity bound. The echo is supposed to be a timestamp WE
                    // minted; anything implausible means a confused or hostile
                    // receiver, and accepting it would let a bogus echo drive our
                    // bitrate to the floor. Treat it as unmeasured instead.
                    stats.roundTripMillis = millis < 5_000 ? millis : 0
                } else {
                    // Echo is in our future: also not a usable measurement.
                    stats.roundTripMillis = 0
                }
            }
            let rtt = stats.roundTripMillis
            let decoded = message.decodedFrames ?? 0
            let dropped = message.droppedFrames ?? 0
            lock.unlock()

            // Task 4.3: drop rate must come from the DELTA between reports, not
            // cumulative totals. Using totals means a receiver that ever dropped
            // frames reports an elevated rate forever, so the controller can only
            // ever ratchet downward and never sees the link clear again.
            lock.lock()
            let deltaDecoded = max(0, decoded - previousDecodedFrames)
            let deltaDropped = max(0, dropped - previousDroppedFrames)
            previousDecodedFrames = decoded
            previousDroppedFrames = dropped
            lock.unlock()

            let windowTotal = deltaDecoded + deltaDropped
            let dropRate = windowTotal > 0 ? Double(deltaDropped) / Double(windowTotal) : 0
            onReceiverReport?(rtt, dropRate)

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

    /// Sends one encoded access unit, or sheds it.
    ///
    /// A slow receiver must not be able to push latency into the stream, so the
    /// encoder is never allowed to run more than one access unit ahead of the
    /// socket: while a send is outstanding the newest frame is dropped instead
    /// of queued. `SendGate` carries the policy and the reasoning; the short
    /// version is that `.contentProcessed` is what makes the back-pressure
    /// observable at all, because its completion is delayed while the send
    /// buffer is full.
    public func send(video message: WireProtocol.VideoMessage) {
        lock.lock()
        let current = client
        let allowed = authorised
        // Enforced HERE as well as at the encode gate, so no future call path
        // can leak video to an unpaired receiver.
        guard let current, allowed else {
            lock.unlock()
            return
        }
        // Decided before encoding: framing a frame we are about to drop would
        // copy the whole payload for nothing, and under congestion most frames
        // are dropped.
        let decision = gate.offer()
        if decision == .drop {
            stats.framesDropped += 1
            let note = rollMeasurementWindowLocked()
            lock.unlock()
            if let note { log(note) }
            return
        }
        lock.unlock()

        let framed = WireProtocol.encode(message)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "video", metadata: [metadata])
        current.send(
            content: framed, contentContext: context, isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                // An error here is not handled: the connection's state handler
                // already tears the client down, and reopening the gate is
                // correct either way — the send is no longer outstanding.
                self?.finishVideoSend(on: current)
            })

        lock.lock()
        stats.framesSent += 1
        if message.isKeyframe { stats.keyframesSent += 1 }
        stats.bytesSent += framed.count
        windowFrames += 1
        windowBytes += framed.count
        let note = rollMeasurementWindowLocked()
        lock.unlock()
        if let note { log(note) }
    }

    /// Rolls the one-second measurement window. Caller holds `lock`. Returns a
    /// line to log, once the lock is dropped, when frames were shed in it.
    ///
    /// Reached from both outcomes of `send(video:)`, not just the sending one.
    /// A receiver that has stalled completely produces no sends at all, and
    /// that is exactly when the numbers must not go quiet: hanging this off the
    /// send path alone would leave `sentFPS` reporting the last healthy figure
    /// for as long as the stall lasted, and shed nothing to the log.
    private func rollMeasurementWindowLocked() -> String? {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - windowStart
        guard elapsed >= 1.0 else { return nil }

        stats.sentFPS = Double(windowFrames) / elapsed
        stats.megabitsPerSecond = Double(windowBytes) * 8.0 / elapsed / 1_000_000.0
        let shed = stats.framesDropped - windowDropsAtStart
        windowDropsAtStart = stats.framesDropped
        windowStart = now
        windowFrames = 0
        windowBytes = 0

        guard shed > 0 else { return nil }
        // Only when it happens: a healthy stream stays silent. Without this the
        // shedding is invisible outside a debugger, which is how the opposite
        // behaviour went unnoticed for so long.
        return String(
            format: "shed %d frames in the last second (sent %.0f) — receiver is not keeping up",
            shed, stats.sentFPS)
    }

    /// Runs when the stack has taken the access unit — consumed, not
    /// transmitted. The distinction matters less than the timing: while the
    /// send buffer is full this callback is delayed, and that delay is what
    /// closes the gate and makes the next frame a drop instead of a queue entry.
    private func finishVideoSend(on connection: NWConnection) {
        lock.lock()
        // A completion arriving from a socket we have since replaced must not
        // reopen the gate for its successor.
        guard client === connection else {
            lock.unlock()
            return
        }
        let needsKeyframe = gate.completed(at: Date())
        lock.unlock()
        // Fired outside the lock: the handler reaches into the encoder.
        if needsKeyframe { onKeyframeNeededAfterDrop?() }
    }
}
