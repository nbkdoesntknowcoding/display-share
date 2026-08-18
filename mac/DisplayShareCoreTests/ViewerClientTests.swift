import CoreMedia
import CoreVideo
import Network
import XCTest

@testable import DisplayShareCore

/// Task 8.2 acceptance, end to end and automated.
///
/// A real WebSocket server feeds real encoded frames to the real client. The
/// only thing standing in for Windows is the encoder — everything after the
/// socket is the code that ships. This exists because the previous UI defect in
/// this project shipped precisely because nothing exercised the assembled path,
/// only the pieces.
final class ViewerClientTests: XCTestCase {

    /// Serves a fixed set of messages to the first client that connects.
    private final class StubSender: @unchecked Sendable {
        private var listener: NWListener?
        private var connection: NWConnection?
        private let messages: [Data]
        var port: UInt16 = 0

        init(messages: [Data]) {
            self.messages = messages
        }

        func start() throws {
            let parameters = NWParameters.tcp
            let websocket = NWProtocolWebSocket.Options()
            websocket.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

            let listener = try NWListener(using: parameters, on: .any)
            // Read the port from the ready state rather than polling
            // `listener.port`, which is not reliably populated the moment
            // start() returns.
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.port = listener.port?.rawValue ?? 0
                    ready.signal()
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connection = connection
                connection.stateUpdateHandler = { state in
                    if case .ready = state { self.sendAll(on: connection) }
                }
                connection.start(queue: .global())
            }
            listener.start(queue: .global())
            self.listener = listener
            _ = ready.wait(timeout: .now() + 5)
        }

        private func sendAll(on connection: NWConnection) {
            for message in messages {
                let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
                connection.send(
                    content: message,
                    contentContext: context,
                    isComplete: true,
                    completion: .idempotent
                )
            }
        }

        func stop() {
            connection?.cancel()
            listener?.cancel()
        }
    }

    private func makePixelBuffer(width: Int, height: Int, tick: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let x0 = (tick * 9) % max(width - 48, 1)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    let inBlock = x >= x0 && x < x0 + 48 && y > height / 4 && y < height / 2
                    bytes[offset] = inBlock ? 210 : 20
                    bytes[offset + 1] = inBlock ? 180 : 20
                    bytes[offset + 2] = inBlock ? 60 : 20
                    bytes[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    /// Encodes a clip and wraps each access unit in the wire format.
    private func encodedMessages(width: Int32, height: Int32, count: Int) throws -> [Data] {
        let encoder = H264Encoder(bitrate: 2_000_000)
        let collected = NSMutableArray()
        let lock = NSLock()
        encoder.onEncodedFrame = { frame in
            let message = WireProtocol.VideoMessage(
                isKeyframe: frame.isKeyframe,
                timestampMicros: UInt64(max(0, frame.presentationTime.seconds) * 1_000_000),
                payload: frame.data
            )
            lock.lock()
            collected.add(WireProtocol.encode(message))
            lock.unlock()
        }
        try encoder.start(width: width, height: height, fps: 30)
        for index in 0..<count {
            try encoder.encode(
                makePixelBuffer(width: Int(width), height: Int(height), tick: index),
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 30)
            )
        }
        encoder.stop()
        lock.lock()
        defer { lock.unlock() }
        return collected.compactMap { $0 as? Data }
    }

    func testClientConnectsDecodesAndReportsTheDecodePath() throws {
        let messages = try encodedMessages(width: 640, height: 360, count: 15)
        XCTAssertFalse(messages.isEmpty)

        let sender = StubSender(messages: messages)
        try sender.start()
        XCTAssertGreaterThan(sender.port, 0, "the stub sender never bound a port")
        defer { sender.stop() }

        let client = ViewerClient()
        let framesArrived = expectation(description: "frames displayed")
        framesArrived.expectedFulfillmentCount = 3
        framesArrived.assertForOverFulfill = false

        let connected = expectation(description: "client reports connected")
        connected.assertForOverFulfill = false

        var lastStatus = ViewerClient.Status()
        var sizes: [(Int, Int)] = []

        client.onFrame = { buffer in
            sizes.append((CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)))
            framesArrived.fulfill()
        }
        client.onStatus = { status in
            lastStatus = status
            if status.connected { connected.fulfill() }
        }

        client.connect(host: "127.0.0.1", port: Int(sender.port))
        wait(for: [connected, framesArrived], timeout: 15)
        client.disconnect()

        XCTAssertEqual(sizes.first?.0, 640)
        XCTAssertEqual(sizes.first?.1, 360)
        XCTAssertTrue(lastStatus.connected)
        XCTAssertEqual(lastStatus.decoder.decodeFailures, 0)
        // The HUD requirement: the decode path has to be reportable, not just
        // the pixels correct.
        XCTAssertTrue(
            lastStatus.decoder.decodePath.hasPrefix("VideoToolbox"),
            "decode path was \(lastStatus.decoder.decodePath)"
        )
    }

    func testUnreachableHostReportsRatherThanHanging() {
        let client = ViewerClient()
        let reported = expectation(description: "failure surfaced")
        reported.assertForOverFulfill = false
        client.onStatus = { status in
            // Port 1 on loopback refuses immediately.
            if !status.connected && status.message.contains("Connection lost") {
                reported.fulfill()
            }
        }
        client.connect(host: "127.0.0.1", port: 1)
        wait(for: [reported], timeout: 15)
        client.disconnect()
    }
}
