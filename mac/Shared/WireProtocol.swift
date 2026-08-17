import Foundation

/// Implementation of protocol/SPEC.md v1.
///
/// The framing is deliberately independent of WebSocket so the identical bytes
/// work over raw TCP if a future receiver cannot use WebSocket.
public enum WireProtocol {
    public static let version = 1
    /// length(4) + type(1) + flags(1) + reserved(2) + timestamp(8)
    public static let headerSize = 16
    /// Bytes covered by the `length` field: everything after it.
    public static let lengthPrefixSize = 4

    public enum MessageType: UInt8 {
        case videoAccessUnit = 1
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let keyframe = Flags(rawValue: 1 << 0)
    }

    public struct VideoMessage: Sendable, Equatable {
        public var isKeyframe: Bool
        public var timestampMicros: UInt64
        public var payload: Data

        public init(isKeyframe: Bool, timestampMicros: UInt64, payload: Data) {
            self.isKeyframe = isKeyframe
            self.timestampMicros = timestampMicros
            self.payload = payload
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case tooShort(Int)
        case lengthMismatch(declared: Int, actual: Int)
        case emptyPayload
        case unknownType(UInt8)

        public var description: String {
            switch self {
            case .tooShort(let n): return "message is \(n) bytes, need at least \(WireProtocol.headerSize)"
            case .lengthMismatch(let d, let a): return "length says \(d), message carries \(a)"
            case .emptyPayload: return "access unit has no payload"
            case .unknownType(let t): return "unknown message type \(t)"
            }
        }
    }

    // MARK: - Encoding

    public static func encode(_ message: VideoMessage) -> Data {
        var out = Data(capacity: headerSize + message.payload.count)
        // length covers everything after the length field itself.
        let length = UInt32(headerSize - lengthPrefixSize + message.payload.count)
        out.append(bigEndian: length)
        out.append(MessageType.videoAccessUnit.rawValue)
        out.append(message.isKeyframe ? Flags.keyframe.rawValue : 0)
        out.append(bigEndian: UInt16(0))  // reserved
        out.append(bigEndian: message.timestampMicros)
        out.append(message.payload)
        return out
    }

    // MARK: - Decoding

    public static func decode(_ data: Data) throws -> VideoMessage {
        guard data.count >= headerSize else { throw ParseError.tooShort(data.count) }

        let declared = Int(data.readUInt32BE(at: 0))
        let actual = data.count - lengthPrefixSize
        guard declared == actual else {
            throw ParseError.lengthMismatch(declared: declared, actual: actual)
        }

        let rawType = data[data.startIndex + 4]
        guard let type = MessageType(rawValue: rawType), type == .videoAccessUnit else {
            throw ParseError.unknownType(rawType)
        }

        let flags = Flags(rawValue: data[data.startIndex + 5])
        let timestamp = data.readUInt64BE(at: 8)
        let payload = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        guard !payload.isEmpty else { throw ParseError.emptyPayload }

        return VideoMessage(
            isKeyframe: flags.contains(.keyframe),
            timestampMicros: timestamp,
            payload: payload)
    }

    // MARK: - Codec string (SPEC §3.3)

    /// Derives the WebCodecs codec string (e.g. "avc1.640028") from the SPS in
    /// an Annex-B payload. Returns nil when no SPS is present.
    public static func codecString(fromAnnexB payload: Data) -> String? {
        let bytes = [UInt8](payload)
        var index = 0
        while index + 4 < bytes.count {
            // Locate a 4-byte start code.
            guard bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1
            else {
                index += 1
                continue
            }
            let naluStart = index + 4
            guard naluStart + 3 < bytes.count else { return nil }
            let naluType = bytes[naluStart] & 0x1F
            if naluType == 7 {  // SPS
                let profile = bytes[naluStart + 1]
                let constraints = bytes[naluStart + 2]
                let level = bytes[naluStart + 3]
                return String(format: "avc1.%02X%02X%02X", profile, constraints, level)
            }
            index = naluStart
        }
        return nil
    }
}

// MARK: - Control channel (SPEC §4)

public struct ReceiverPanel: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var scale: Double
    public var refreshRate: Int

    public init(width: Int, height: Int, scale: Double = 1.0, refreshRate: Int = 60) {
        self.width = width
        self.height = height
        self.scale = scale
        self.refreshRate = refreshRate
    }
}

public struct VideoFormat: Codable, Equatable, Sendable {
    public var codec: String
    public var width: Int
    public var height: Int
    public var fps: Int

    public init(codec: String = "h264", width: Int, height: Int, fps: Int) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
    }
}

/// One JSON envelope for every control message. Unknown `type` values decode
/// with all-nil fields and MUST be ignored by the receiver (SPEC §4).
public struct ControlMessage: Codable, Equatable, Sendable {
    public var type: String
    public var protocolVersion: Int?
    public var client: String?
    public var sender: String?
    public var receiver: ReceiverPanel?
    public var video: VideoFormat?
    public var width: Int?
    public var height: Int?
    public var codec: String?
    public var fps: Int?
    public var code: String?
    public var message: String?
    public var decodedFrames: Int?
    public var droppedFrames: Int?
    public var decodeMillis: Double?
    public var queuedFrames: Int?
    public var lastTimestamp: UInt64?
    // Pairing (SPEC §4.7-4.9)
    public var deviceId: String?
    public var deviceName: String?
    public var pin: String?
    public var token: String?
    /// Forwarded input batch (SPEC §4.10).
    public var events: [ForwardedInputEvent]?

    public init(type: String) { self.type = type }

    public static func welcome(video: VideoFormat, sender: String) -> ControlMessage {
        var m = ControlMessage(type: "welcome")
        m.protocolVersion = WireProtocol.version
        m.video = video
        m.sender = sender
        return m
    }

    public static func videoFormat(_ format: VideoFormat) -> ControlMessage {
        var m = ControlMessage(type: "video_format")
        m.codec = format.codec
        m.width = format.width
        m.height = format.height
        m.fps = format.fps
        return m
    }

    public static func error(code: String, message: String) -> ControlMessage {
        var m = ControlMessage(type: "error")
        m.code = code
        m.message = message
        return m
    }

    public static func hello(panel: ReceiverPanel, client: String) -> ControlMessage {
        var m = ControlMessage(type: "hello")
        m.protocolVersion = WireProtocol.version
        m.receiver = panel
        m.client = client
        return m
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func append(bigEndian value: UInt16) {
        for shift in stride(from: 8, through: 0, by: -8) { append(UInt8((value >> UInt16(shift)) & 0xFF)) }
    }
    mutating func append(bigEndian value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
    mutating func append(bigEndian value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { append(UInt8((value >> UInt64(shift)) & 0xFF)) }
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16)
            | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for k in 0..<8 { value = (value << 8) | UInt64(self[startIndex + offset + k]) }
        return value
    }
}
