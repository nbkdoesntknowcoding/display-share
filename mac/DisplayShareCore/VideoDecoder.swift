import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// H.264 decoding with VideoToolbox for the Mac viewer (Task 8.2).
///
/// A `VTDecompressionSession` rather than handing compressed samples straight to
/// `AVSampleBufferDisplayLayer`: the layer would decode them perfectly well, but
/// it will not say HOW, and the acceptance for this task is that the decode path
/// is visible in the HUD. A session can be asked whether it is running on
/// hardware.
public final class VideoDecoder {

    public struct Stats: Sendable, Equatable {
        public var framesDecoded = 0
        /// Frames refused because no keyframe had established a format yet.
        public var framesSkipped = 0
        public var decodeFailures = 0
        public var width = 0
        public var height = 0
        public var usingHardware = false
        /// Mean decode time in milliseconds over the frames seen so far.
        public var meanDecodeMs = 0.0

        public init() {}

        public var decodePath: String {
            guard width > 0 else { return "waiting for keyframe" }
            return usingHardware ? "VideoToolbox (hardware)" : "VideoToolbox (software)"
        }
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case formatCreationFailed(OSStatus)
        case sessionCreationFailed(OSStatus)
        case blockBufferFailed(OSStatus)
        case sampleBufferFailed(OSStatus)

        public var description: String {
            switch self {
            case .formatCreationFailed(let s): return "could not build a format description (\(s))"
            case .sessionCreationFailed(let s): return "could not create a decompression session (\(s))"
            case .blockBufferFailed(let s): return "could not wrap the sample data (\(s))"
            case .sampleBufferFailed(let s): return "could not build a sample buffer (\(s))"
            }
        }
    }

    public private(set) var stats = Stats()

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    /// The parameter sets the current session was built from, so an unchanged
    /// SPS on every keyframe does not rebuild it 60 times a second.
    private var currentParameterSets: (sps: [Data], pps: [Data])?
    private var totalDecodeSeconds = 0.0

    public init() {}

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Decodes one access unit. Returns nil when there is nothing to show yet.
    public func decode(_ message: WireProtocol.VideoMessage) throws -> CVImageBuffer? {
        if message.isKeyframe {
            try configureIfNeeded(from: message.payload)
        }
        // Before the first keyframe there is no format description, and feeding
        // a delta frame to a session that does not exist would fail once per
        // frame. Skipping is the correct behaviour, not an error.
        guard let session, let formatDescription else {
            stats.framesSkipped += 1
            return nil
        }

        let avcc = AnnexB.avcc(message.payload)
        guard !avcc.isEmpty else {
            stats.framesSkipped += 1
            return nil
        }

        let sampleBuffer = try makeSampleBuffer(
            avcc: avcc,
            formatDescription: formatDescription,
            timestampMicros: message.timestampMicros
        )

        let started = CFAbsoluteTimeGetCurrent()
        var decoded: CVImageBuffer?
        var handlerStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: nil
        ) { outputStatus, _, imageBuffer, _, _ in
            handlerStatus = outputStatus
            decoded = imageBuffer
        }

        guard status == noErr, handlerStatus == noErr else {
            stats.decodeFailures += 1
            return nil
        }

        stats.framesDecoded += 1
        totalDecodeSeconds += CFAbsoluteTimeGetCurrent() - started
        stats.meanDecodeMs = totalDecodeSeconds / Double(stats.framesDecoded) * 1000

        if let decoded {
            stats.width = CVPixelBufferGetWidth(decoded)
            stats.height = CVPixelBufferGetHeight(decoded)
        }
        return decoded
    }

    /// Rebuilds the session when the stream's parameter sets change.
    ///
    /// A resolution change on the Windows side arrives as new SPS/PPS on the
    /// next keyframe; continuing with the old session decodes garbage rather
    /// than reporting anything.
    private func configureIfNeeded(from payload: Data) throws {
        let sets = AnnexB.parameterSets(payload)
        guard let sps = sets.sps.first, let pps = sets.pps.first else { return }
        if let current = currentParameterSets, current.sps.first == sps, current.pps.first == pps {
            return
        }

        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBuffer -> OSStatus in
            pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                let pointers = [
                    spsBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBuffer.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    // AVCC uses 4-byte length prefixes, matching AnnexB.avcc.
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else { throw DecodeError.formatCreationFailed(status) }

        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        // BGRA out: it is what the display layer wants, and letting VideoToolbox
        // do the conversion keeps it on the GPU.
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var newSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard sessionStatus == noErr, let newSession else {
            throw DecodeError.sessionCreationFailed(sessionStatus)
        }

        session = newSession
        formatDescription = format
        currentParameterSets = (sets.sps, sets.pps)

        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        stats.width = Int(dimensions.width)
        stats.height = Int(dimensions.height)
        stats.usingHardware = Self.isHardwareBacked(newSession)
    }

    private static func isHardwareBacked(_ session: VTDecompressionSession) -> Bool {
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(
            session,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &value
        )
        guard status == noErr, let flag = value as? Bool else { return false }
        return flag
    }

    private func makeSampleBuffer(
        avcc: Data,
        formatDescription: CMVideoFormatDescription,
        timestampMicros: UInt64
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var storage = avcc
        let blockStatus = storage.withUnsafeMutableBytes { buffer -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: buffer.baseAddress,
                blockLength: buffer.count,
                // The bytes are copied below, so this buffer must NOT be freed
                // by CoreMedia — it belongs to the local `storage`.
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: buffer.count,
                flags: 0,
                blockBufferOut: &block
            )
        }
        guard blockStatus == noErr, let block else { throw DecodeError.blockBufferFailed(blockStatus) }

        // Copy into CoreMedia-owned storage: `storage` dies at the end of this
        // call, and the decoder may still be reading.
        var owned: CMBlockBuffer?
        let copyStatus = CMBlockBufferCreateContiguous(
            allocator: kCFAllocatorDefault,
            sourceBuffer: block,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: 0,
            flags: kCMBlockBufferAlwaysCopyDataFlag,
            blockBufferOut: &owned
        )
        guard copyStatus == noErr, let owned else { throw DecodeError.blockBufferFailed(copyStatus) }

        var sampleBuffer: CMSampleBuffer?
        var size = avcc.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: owned,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw DecodeError.sampleBufferFailed(sampleStatus)
        }
        return sampleBuffer
    }
}
