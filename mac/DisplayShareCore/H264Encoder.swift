import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder for the live path.
///
/// Configuration here is dictated by what the receiver can decode, not by what
/// produces the smallest file:
///
/// * **RealTime = true** — encode in lockstep with capture rather than buffering
///   for efficiency.
/// * **AllowFrameReordering = false** — no B-frames. WebCodecs decoders do not
///   support them in low-latency mode, so a B-frame is not a quality trade-off,
///   it is a broken stream.
/// * **Annex-B output with in-band SPS/PPS** — VideoToolbox emits AVCC
///   (length-prefixed NALUs with parameter sets held out-of-band in the format
///   description). We rewrite to start-code framing and re-inject SPS/PPS ahead
///   of every keyframe, so a receiver that joins mid-stream can start decoding
///   from the next IDR without a side channel.
public final class H264Encoder: @unchecked Sendable {

    public struct Statistics: Sendable {
        public var framesEncoded: Int = 0
        public var keyframes: Int = 0
        public var bytesProduced: Int = 0
        public var lastEncodeMillis: Double = 0
        public var averageEncodeMillis: Double = 0
        public var lastFrameBytes: Int = 0
    }

    public enum EncoderError: Error, CustomStringConvertible {
        case sessionCreationFailed(OSStatus)
        case propertyFailed(String, OSStatus)
        case encodeFailed(OSStatus)
        case notStarted

        public var description: String {
            switch self {
            case .sessionCreationFailed(let s): return "VTCompressionSessionCreate failed (\(s))"
            case .propertyFailed(let k, let s): return "could not set \(k) (\(s))"
            case .encodeFailed(let s): return "VTCompressionSessionEncodeFrame failed (\(s))"
            case .notStarted: return "encoder has not been started"
            }
        }
    }

    /// One encoded access unit in Annex-B form, already carrying SPS/PPS when
    /// it is a keyframe.
    public struct EncodedFrame: Sendable {
        public let data: Data
        public let isKeyframe: Bool
        public let presentationTime: CMTime
        public let encodeMillis: Double
    }

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var stats = Statistics()
    private var encodeStartTimes: [Int64: CFAbsoluteTime] = [:]
    private var totalEncodeSeconds: Double = 0

    private(set) public var width: Int32 = 0
    private(set) public var height: Int32 = 0

    /// Called on VideoToolbox's callback thread for every encoded frame.
    public var onEncodedFrame: ((EncodedFrame) -> Void)?

    public private(set) var bitrate: Int

    /// Whether the low-latency encoder was actually granted for this session.
    ///
    /// Reported rather than assumed: the specification selects an encoder, and
    /// if none is available the session is created without it. A build quietly
    /// running the ordinary encoder would otherwise be indistinguishable from
    /// one running the low-latency path.
    public private(set) var lowLatencyRateControl = false

    /// Which VideoToolbox encoder was actually instantiated, read back from
    /// the session rather than inferred.
    ///
    /// Worth having in a bug report on its own: the low-latency and ordinary
    /// encoders are different implementations with different property sets
    /// (`ConstantBitRate` and `EnableTransform8x8`, for instance, exist only on
    /// the ordinary one), so "which encoder" explains behaviour that otherwise
    /// looks like a machine-specific mystery.
    public private(set) var encoderID: String?

    /// How long the encoder may go without emitting a keyframe unasked.
    ///
    /// A backstop, not a mechanism — see `start(width:height:fps:)`.
    static let keyframeBackstopSeconds = 10

    /// The encoder specification that selects the low-latency H.264 encoder.
    ///
    /// Built here so it can be asserted without creating a session.
    static var lowLatencySpecification: CFDictionary {
        [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!]
            as CFDictionary
    }

    public init(bitrate: Int = 12_000_000) {
        self.bitrate = bitrate
    }

    deinit { stop() }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    // MARK: - Lifecycle

    public func start(width: Int32, height: Int32, fps: Int) throws {
        stop()
        self.width = width
        self.height = height

        // Low-latency mode is chosen HERE, at session creation, and nowhere
        // else: `EnableLowLatencyRateControl` is an encoder *specification*, so
        // it selects which encoder is instantiated. No amount of
        // VTSessionSetProperty afterwards is equivalent, which is why this was
        // missed for so long — every other knob on this encoder is a property.
        //
        // What it buys: a strict one-in/one-out pattern instead of an internal
        // pipeline, and a rate controller that adapts faster to a changing
        // link. Apple quotes up to 100ms for 720p30, though part of that comes
        // from eliminating frame reordering, which `AllowFrameReordering =
        // false` below already gives us — so expect less than the headline and
        // measure rather than quoting it.
        //
        // H.264 only, and mutually exclusive with ConstantBitRate. We use
        // AverageBitRate plus DataRateLimits, so there is no conflict.
        var newSession: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: Self.lowLatencySpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession)
        lowLatencyRateControl = status == noErr && newSession != nil

        // Fall back rather than refuse to start. A machine with no low-latency
        // encoder should still share its screen — worse latency is a bad
        // session, no session is a broken app.
        if !lowLatencyRateControl {
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &newSession)
        }

        guard status == noErr, let created = newSession else {
            throw EncoderError.sessionCreationFailed(status)
        }

        // Read back which encoder we got. `lowLatencyRateControl` above is an
        // inference — creation with the specification succeeded — and an
        // inference cannot notice if the specification stops being passed.
        // This can: the two encoders report different identifiers.
        var identifier: CFTypeRef?
        if VTSessionCopyProperty(
            created, key: kVTCompressionPropertyKey_EncoderID, allocator: nil,
            valueOut: &identifier) == noErr
        {
            encoderID = identifier as? String
        }

        func set(_ key: CFString, _ value: CFTypeRef, _ label: String) throws {
            let s = VTSessionSetProperty(created, key: key, value: value)
            guard s == noErr else { throw EncoderError.propertyFailed(label, s) }
        }

        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
        // No B-frames: WebCodecs cannot handle them in low-latency mode.
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering")
        try set(
            kVTCompressionPropertyKey_ProfileLevel,
            kVTProfileLevel_H264_High_AutoLevel, "ProfileLevel")
        try set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate), "AverageBitRate")
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps), "ExpectedFrameRate")
        // Keyframes on request, with a long backstop rather than a short one.
        //
        // An IDR is several times the size of a delta frame, so every periodic
        // one is a burst the link has to absorb at once. At the old two-second
        // interval that burst arrived thirty times a minute, and each one is a
        // chance to fill the send buffer, shed frames and put a hitch on screen
        // — a cost paid continuously against a case that hardly ever happens.
        //
        // Nothing actually depends on the periodic ones. Every real path asks:
        // a receiver requests an IDR when it connects, when it cannot decode,
        // and when the format changes, and the send gate requests a repair
        // after it sheds. The transport is TCP, so there is no packet loss to
        // recover from without the connection going with it.
        //
        // Ten seconds, then, as insurance against a request that never arrives
        // rather than as the mechanism. Five times fewer bursts, and a worst
        // case nobody should ever reach.
        try set(
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            NSNumber(value: fps * Self.keyframeBackstopSeconds), "MaxKeyFrameInterval")
        try set(
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            NSNumber(value: Double(Self.keyframeBackstopSeconds)),
            "MaxKeyFrameIntervalDuration")
        // Cap instantaneous rate so a scene change cannot spike the wire and
        // blow the latency budget: bitrate bytes over 1 second.
        let limits = [NSNumber(value: bitrate / 8), NSNumber(value: 1.0)] as CFArray
        try? set(kVTCompressionPropertyKey_DataRateLimits, limits, "DataRateLimits")

        VTCompressionSessionPrepareToEncodeFrames(created)

        lock.lock()
        session = created
        stats = Statistics()
        totalEncodeSeconds = 0
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let current = session
        session = nil
        lock.unlock()

        guard let current else { return }
        VTCompressionSessionCompleteFrames(current, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(current)
    }

    /// Live bitrate change, for Task 4.3 adaptive bitrate.
    public func setBitrate(_ newValue: Int) {
        lock.lock()
        bitrate = newValue
        let current = session
        lock.unlock()
        guard let current else { return }
        VTSessionSetProperty(
            current, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: newValue))
        let limits = [NSNumber(value: newValue / 8), NSNumber(value: 1.0)] as CFArray
        VTSessionSetProperty(current, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    // MARK: - Encoding

    /// Set to force the next frame to be an IDR — used on client connect and on
    /// an explicit `request_keyframe` from the receiver.
    private var forceKeyframeRequested = false

    public func requestKeyframe() {
        lock.lock()
        forceKeyframeRequested = true
        lock.unlock()
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        lock.lock()
        guard let current = session else {
            lock.unlock()
            throw EncoderError.notStarted
        }
        let forceKey = forceKeyframeRequested
        forceKeyframeRequested = false
        encodeStartTimes[presentationTime.value] = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        var properties: CFDictionary?
        if forceKey {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            current,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            self.handleEncoded(sampleBuffer)
        }
        guard status == noErr else { throw EncoderError.encodeFailed(status) }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
            let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let isKeyframe = Self.isKeyframe(sampleBuffer)

        var annexB = Data()

        // In-band parameter sets ahead of every IDR, so a receiver joining
        // mid-stream can configure its decoder from the stream alone.
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            annexB.append(Self.parameterSetsAnnexB(format))
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength, dataPointerOut: &pointer) == noErr,
            let base = pointer
        else { return }

        // AVCC -> Annex-B: swap each big-endian length prefix for a start code.
        let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var offset = 0
        let headerLength = 4
        while offset + headerLength <= totalLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, bytes + offset, headerLength)
            naluLength = CFSwapInt32BigToHost(naluLength)
            offset += headerLength
            guard naluLength > 0, offset + Int(naluLength) <= totalLength else { break }
            annexB.append(contentsOf: startCode)
            annexB.append(bytes + offset, count: Int(naluLength))
            offset += Int(naluLength)
        }

        lock.lock()
        let started = encodeStartTimes.removeValue(forKey: presentationTime.value)
        let elapsed = started.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0
        stats.framesEncoded += 1
        if isKeyframe { stats.keyframes += 1 }
        stats.bytesProduced += annexB.count
        stats.lastFrameBytes = annexB.count
        stats.lastEncodeMillis = elapsed
        totalEncodeSeconds += elapsed
        stats.averageEncodeMillis = totalEncodeSeconds / Double(stats.framesEncoded)
        // Bound the map if a frame's callback never arrives.
        if encodeStartTimes.count > 120 { encodeStartTimes.removeAll() }
        lock.unlock()

        onEncodedFrame?(
            EncodedFrame(
                data: annexB, isKeyframe: isKeyframe,
                presentationTime: presentationTime, encodeMillis: elapsed))
    }

    // MARK: - Helpers

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
            let first = attachments.first
        else { return true }
        // Absence of NotSync means this IS a sync sample.
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { return !notSync }
        return true
    }

    /// SPS and PPS as Annex-B NALUs, pulled from the format description.
    static func parameterSetsAnnexB(_ format: CMFormatDescription) -> Data {
        var out = Data()
        var count = 0
        guard
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr
        else { return out }

        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let pointer
            else { continue }
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(pointer, count: size)
        }
        return out
    }
}
