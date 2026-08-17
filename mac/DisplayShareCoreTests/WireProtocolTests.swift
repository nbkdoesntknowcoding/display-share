import XCTest

@testable import DisplayShareCore

/// Task 2.2 acceptance: the golden vectors in protocol/vectors/ must round-trip,
/// and every malformed vector must be rejected. These same vectors drive the
/// TypeScript parser on the Windows side, so both ends are tested independently.
final class WireProtocolTests: XCTestCase {

    private struct Manifest: Decodable {
        struct Vector: Decodable {
            let file: String
            let description: String
            let expect: String
            let isKeyframe: Bool?
            /// String, not a number: JSON cannot represent 2^64-1 exactly.
            let timestampMicros: String?
            let payloadBytes: Int?
            let codecString: String?
            let reason: String?
        }
        let protocolVersion: Int
        let headerSize: Int
        let vectors: [Vector]
    }

    /// Walks up from this source file to the repo root, so the test does not
    /// depend on where DerivedData happens to be.
    private var vectorsDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }  // mac/DisplayShareCoreTests/<file>
        return url.appendingPathComponent("protocol/vectors")
    }

    private func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: vectorsDirectory.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    func testManifestMatchesImplementation() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.protocolVersion, WireProtocol.version)
        XCTAssertEqual(manifest.headerSize, WireProtocol.headerSize)
    }

    func testGoldenVectors() throws {
        let manifest = try loadManifest()
        XCTAssertFalse(manifest.vectors.isEmpty)

        for vector in manifest.vectors {
            let data = try Data(contentsOf: vectorsDirectory.appendingPathComponent(vector.file))

            switch vector.expect {
            case "accept":
                let message = try WireProtocol.decode(data)
                XCTAssertEqual(message.isKeyframe, vector.isKeyframe, vector.file)
                XCTAssertEqual(message.timestampMicros, vector.timestampMicros.flatMap(UInt64.init), vector.file)
                XCTAssertEqual(message.payload.count, vector.payloadBytes, vector.file)
                XCTAssertEqual(
                    WireProtocol.codecString(fromAnnexB: message.payload), vector.codecString, vector.file)

                // Re-encoding an accepted message must reproduce the vector byte for byte.
                XCTAssertEqual(WireProtocol.encode(message), data, "re-encode mismatch: \(vector.file)")

            case "reject":
                XCTAssertThrowsError(try WireProtocol.decode(data), vector.file) { error in
                    guard let parseError = error as? WireProtocol.ParseError else {
                        return XCTFail("wrong error type for \(vector.file): \(error)")
                    }
                    switch (vector.reason, parseError) {
                    case ("emptyPayload", .emptyPayload),
                        ("tooShort", .tooShort),
                        ("lengthMismatch", .lengthMismatch):
                        break
                    default:
                        XCTFail("\(vector.file): expected \(vector.reason ?? "?"), got \(parseError)")
                    }
                }

            default:
                XCTFail("unknown expectation '\(vector.expect)' for \(vector.file)")
            }
        }
    }

    func testRoundTripAcrossRepresentativePayloads() throws {
        let cases: [(Bool, UInt64, Int)] = [
            (true, 0, 1),
            (false, 1, 64),
            (true, UInt64.max, 4096),
            (false, 1_234_567_890, 65_535),
        ]
        for (isKeyframe, timestamp, size) in cases {
            let payload = Data((0..<size).map { UInt8($0 % 251) })
            let original = WireProtocol.VideoMessage(
                isKeyframe: isKeyframe, timestampMicros: timestamp, payload: payload)
            let decoded = try WireProtocol.decode(WireProtocol.encode(original))
            XCTAssertEqual(decoded, original)
        }
    }

    /// The length field must cover everything after itself — an off-by-four here
    /// would desynchronise a raw-TCP reader on the very first frame.
    func testLengthFieldCoversEverythingAfterItself() {
        let payload = Data(repeating: 0xAB, count: 100)
        let encoded = WireProtocol.encode(
            .init(isKeyframe: false, timestampMicros: 7, payload: payload))
        let declared = Int(encoded.readUInt32BE(at: 0))
        XCTAssertEqual(declared, encoded.count - 4)
        XCTAssertEqual(declared, WireProtocol.headerSize - 4 + payload.count)
    }

    func testCodecStringFromRealSPS() {
        // High profile (0x64), constraints 0x00, level 4.0 (0x28).
        var payload = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x28, 0xAC])
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x65, 0x88])
        XCTAssertEqual(WireProtocol.codecString(fromAnnexB: payload), "avc1.640028")
    }

    func testCodecStringNilWithoutSPS() {
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x9A, 0x00])
        XCTAssertNil(WireProtocol.codecString(fromAnnexB: payload))
    }

    func testControlMessagesRoundTripAsJSON() throws {
        let hello = ControlMessage.hello(
            panel: ReceiverPanel(width: 1920, height: 1080, scale: 1.5, refreshRate: 60),
            client: "test/1.0")
        let data = try JSONEncoder().encode(hello)
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
        XCTAssertEqual(decoded, hello)
        XCTAssertEqual(decoded.protocolVersion, WireProtocol.version)
        XCTAssertEqual(decoded.receiver?.scale, 1.5)
    }

    /// SPEC §4: unknown control types must decode without throwing so either
    /// side can add messages without a version bump.
    func testUnknownControlTypeDecodesAndIsIgnorable() throws {
        let json = Data(#"{"type":"something_new_in_v2","somethingElse":42}"#.utf8)
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: json)
        XCTAssertEqual(decoded.type, "something_new_in_v2")
        XCTAssertNil(decoded.video)
    }
}
