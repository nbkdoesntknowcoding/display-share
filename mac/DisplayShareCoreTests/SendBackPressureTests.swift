import Darwin
import Foundation
import XCTest

@testable import DisplayShareCore

/// The half of the back-pressure fix that `SendGateTests` cannot reach.
///
/// The unit tests drive the policy directly, so they prove what the gate does
/// once it is closed — they cannot prove it ever closes, because that depends
/// on Network.framework delaying the `.contentProcessed` completion while the
/// send buffer is full. Only a real socket with a real stalled reader shows
/// that, so this drives the actual `WebSocketServer` send path over loopback
/// against a client that stops calling `recv`.
///
/// This is the automated form of "throttle the link and watch the drop counter".
final class SendBackPressureTests: XCTestCase {

    // MARK: - A hand-rolled client

    /// Deliberately a raw POSIX socket rather than NWConnection: the test needs
    /// "this peer is not reading" to mean the kernel receive buffer fills and
    /// the window shuts. A framework client would keep draining into a buffer
    /// of its own and hide the very stall being tested.
    private final class RawClient: @unchecked Sendable {
        let fd: Int32

        init?(port: UInt16, receiveBuffer: Int32) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            // Small, and set before connect so the advertised window starts
            // small — otherwise loopback auto-tuning swallows the whole test.
            var size = receiveBuffer
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                close(fd)
                return nil
            }
            self.fd = fd
        }

        deinit { close(fd) }

        func writeAll(_ bytes: [UInt8]) {
            var sent = 0
            bytes.withUnsafeBufferPointer { buffer in
                while sent < bytes.count {
                    let n = write(fd, buffer.baseAddress! + sent, bytes.count - sent)
                    if n <= 0 { return }
                    sent += n
                }
            }
        }

        /// RFC 6455: client frames must be masked.
        func sendFrame(_ payload: [UInt8], opcode: UInt8) {
            var frame: [UInt8] = [0x80 | opcode]
            let n = payload.count
            if n < 126 {
                frame.append(0x80 | UInt8(n))
            } else if n < 65536 {
                frame.append(0x80 | 126)
                frame.append(UInt8(n >> 8))
                frame.append(UInt8(n & 0xFF))
            } else {
                frame.append(0x80 | 127)
                for shift in stride(from: 56, through: 0, by: -8) {
                    frame.append(UInt8((n >> shift) & 0xFF))
                }
            }
            let mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }
            frame.append(contentsOf: mask)
            for (i, byte) in payload.enumerated() { frame.append(byte ^ mask[i % 4]) }
            writeAll(frame)
        }

        /// Opens the WebSocket. The response is parsed only far enough to
        /// confirm the upgrade — this test is about the send path, and
        /// protocol/vectors already covers framing.
        func handshake(port: UInt16) -> Bool {
            let request = """
                GET / HTTP/1.1\r
                Host: 127.0.0.1:\(port)\r
                Upgrade: websocket\r
                Connection: Upgrade\r
                Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
                Sec-WebSocket-Version: 13\r
                \r\n
                """
            writeAll(Array(request.utf8))

            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { return false }
                response.append(contentsOf: buffer[0..<n])
                if response.range(of: Data("\r\n\r\n".utf8)) != nil {
                    return String(decoding: response, as: UTF8.self).contains(" 101 ")
                }
            }
            return false
        }

        /// Drains whatever has arrived. Returns bytes read.
        @discardableResult
        func drain(for seconds: TimeInterval) -> Int {
            var flags = fcntl(fd, F_GETFL, 0)
            flags |= O_NONBLOCK
            _ = fcntl(fd, F_SETFL, flags)

            var total = 0
            var buffer = [UInt8](repeating: 0, count: 65536)
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n > 0 {
                    total += n
                } else {
                    usleep(2_000)
                }
            }
            return total
        }
    }

    // MARK: - Harness

    private func makeFrame(bytes: Int, keyframe: Bool = false) -> WireProtocol.VideoMessage {
        .init(
            isKeyframe: keyframe,
            timestampMicros: UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000),
            payload: Data(repeating: 0xAB, count: bytes))
    }

    /// Starts a server on a free high port, with a client attached and
    /// authorised. `pairing` is nil so `hello` completes the handshake outright,
    /// and `videoFormat` is left nil so no `welcome` is queued ahead of video.
    private func startServerWithAuthorisedClient() throws -> (WebSocketServer, RawClient) {
        for _ in 0..<12 {
            let port = UInt16.random(in: 20_000...60_000)
            let server = WebSocketServer(port: port, pairing: nil)
            do {
                try server.start()
            } catch {
                continue
            }

            let ready = expectation(description: "handshake")
            server.onClientReady = { _ in ready.fulfill() }

            // NWListener binds asynchronously — start() returns well before
            // the port accepts, so a single connect attempt races it and the
            // whole harness silently skips.
            var attached: RawClient?
            let bindDeadline = Date().addingTimeInterval(3.0)
            while Date() < bindDeadline {
                if let candidate = RawClient(port: port, receiveBuffer: 8 * 1024) {
                    attached = candidate
                    break
                }
                usleep(25_000)
            }
            guard let client = attached, client.handshake(port: port) else {
                server.stop()
                continue
            }

            let hello = """
                {"type":"hello","protocolVersion":1,"client":"backpressure-test/1.0",\
                "deviceId":"bp-device","deviceName":"BackPressure"}
                """
            client.sendFrame(Array(hello.utf8), opcode: 0x1)

            wait(for: [ready], timeout: 5)
            XCTAssertTrue(server.hasAuthorisedClient)
            return (server, client)
        }
        throw XCTSkip("could not bind a loopback port for the back-pressure harness")
    }

    // MARK: - Tests

    /// A reader that keeps up must not be shed — otherwise the gate would be
    /// trading away frames it never needed to.
    func testAHealthyReaderIsNotShed() throws {
        let (server, client) = try startServerWithAuthorisedClient()
        defer { server.stop() }

        let draining = Thread { client.drain(for: 4.0) }
        draining.start()

        // ~60fps of 20KB frames: about 10 Mbps, which loopback does not notice.
        let offered = 120
        for _ in 0..<offered {
            server.send(video: makeFrame(bytes: 20 * 1024))
            usleep(16_000)
        }
        Thread.sleep(forTimeInterval: 0.5)

        let stats = server.statistics
        XCTAssertEqual(
            stats.framesSent + stats.framesDropped, offered,
            "every offered frame must be accounted for as sent or shed")
        XCTAssertLessThan(
            Double(stats.framesDropped) / Double(offered), 0.10,
            "an uncongested link shed \(stats.framesDropped)/\(offered) frames")
    }

    /// The headline behaviour. A receiver that stops reading fills the send
    /// buffer, `.contentProcessed` stops firing, and frames are shed. Before
    /// this change the same run reported zero drops and buffered every byte.
    func testAStalledReaderShedsFramesInsteadOfQueueing() throws {
        let (server, client) = try startServerWithAuthorisedClient()
        defer { server.stop() }
        // The client is never read from in this test, but it must stay alive:
        // its deinit closes the socket, which would end the stall being tested.
        defer { withExtendedLifetime(client) {} }

        // Let the connection settle without ever draining it.
        Thread.sleep(forTimeInterval: 0.2)

        let offered = 240
        let frameBytes = 32 * 1024
        for _ in 0..<offered {
            server.send(video: makeFrame(bytes: frameBytes))
            usleep(16_000)
        }
        Thread.sleep(forTimeInterval: 0.3)

        let stats = server.statistics
        print(
            "[stalled receiver] offered \(offered) frames"
                + " (\(offered * frameBytes / 1024)KB), sent \(stats.framesSent),"
                + " shed \(stats.framesDropped),"
                + " handed \(stats.bytesSent / 1024)KB to the socket")
        XCTAssertEqual(stats.framesSent + stats.framesDropped, offered)

        // The proof: the counter moves at all. This is the assertion that fails
        // against `.idempotent`, where nothing is ever shed.
        XCTAssertGreaterThan(
            stats.framesDropped, 0,
            "a stalled receiver produced no drops — the send path is buffering again")

        // And it moves decisively: a ~4s stall at 60fps cannot have been
        // absorbed honestly.
        XCTAssertGreaterThan(
            Double(stats.framesDropped) / Double(offered), 0.5,
            "only \(stats.framesDropped)/\(offered) shed under a full stall")

        // The reported rate has to follow reality too. Measured only on the
        // sending path it would sit at the last healthy figure for the whole
        // stall, which is the same class of lie the drop counter was telling.
        XCTAssertLessThan(
            stats.sentFPS, 5,
            "a fully stalled stream still reported \(stats.sentFPS) fps")

        // What was handed to the socket is bounded by the buffers, not by how
        // long the stall lasted. Offered here is ~7.5MB.
        XCTAssertLessThan(
            stats.bytesSent, 4 * 1024 * 1024,
            "handed \(stats.bytesSent) bytes to a socket nobody was reading")
    }

    /// Latency is the product, so the thing that actually matters is what the
    /// receiver sees when it comes back: a current frame, not a backlog to chew
    /// through. Bounded backlog is the same statement as bounded added latency.
    func testBacklogAfterAStallIsBoundedNotProportionalToIt() throws {
        let (server, client) = try startServerWithAuthorisedClient()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.2)

        // Stall for 3 seconds at ~60fps of 32KB frames — 5.6MB offered.
        let frameBytes = 32 * 1024
        var offered = 0
        let stallUntil = Date().addingTimeInterval(3.0)
        while Date() < stallUntil {
            server.send(video: makeFrame(bytes: frameBytes))
            offered += 1
            usleep(16_000)
        }
        let offeredBytes = offered * frameBytes

        // Now the receiver comes back. Everything still in flight drains here.
        let drained = client.drain(for: 2.0)

        print(
            "[3s stall, then resume] offered \(offeredBytes / 1024)KB,"
                + " drained \(drained / 1024)KB on recovery,"
                + " shed \(server.statistics.framesDropped)/\(offered) frames")
        XCTAssertGreaterThan(offeredBytes, 4 * 1024 * 1024, "the stall was too short to be a test")
        XCTAssertLessThan(
            drained, offeredBytes / 3,
            "drained \(drained) of \(offeredBytes) offered bytes — the stall accumulated "
                + "a backlog instead of being shed")
    }

    /// A shed frame breaks the receiver's reference chain and it cannot tell,
    /// so the sender has to ask for the repair itself.
    func testShedFramesRequestARepairKeyframe() throws {
        let (server, client) = try startServerWithAuthorisedClient()
        defer { server.stop() }

        let repairs = NSLock()
        var repairCount = 0
        server.onKeyframeNeededAfterDrop = {
            repairs.lock()
            repairCount += 1
            repairs.unlock()
        }

        // Stall first so frames are definitely shed.
        Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<120 {
            server.send(video: makeFrame(bytes: 32 * 1024))
            usleep(16_000)
        }
        XCTAssertGreaterThan(server.statistics.framesDropped, 0, "precondition: frames were shed")

        // No repair is expected *during* a total stall: the request is raised
        // from the send completion, and while the socket takes nothing there is
        // no completion to raise it from. That is the right behaviour rather
        // than a gap — an IDR minted mid-stall would be shed like everything
        // else, and keyframes are the most expensive thing to waste.
        repairs.lock()
        let duringStall = repairCount
        repairs.unlock()
        XCTAssertEqual(duringStall, 0, "an IDR was minted mid-stall, where it could only be shed")

        // Now the link recovers, which is when the repair can actually land.
        let draining = Thread { client.drain(for: 3.0) }
        draining.start()
        for _ in 0..<120 {
            server.send(video: makeFrame(bytes: 32 * 1024))
            usleep(16_000)
        }
        Thread.sleep(forTimeInterval: 0.5)

        repairs.lock()
        let observed = repairCount
        repairs.unlock()

        XCTAssertGreaterThan(
            observed, 0,
            "the link recovered with frames already shed, but no keyframe was ever requested — "
                + "the receiver would decode against a reference it never got")
        // ~2s of recovery at SPEC §4.5's one-per-250ms ceiling.
        XCTAssertLessThanOrEqual(observed, 15, "keyframe storm: \(observed) IDRs requested")
    }
}
