import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest

@testable import DisplayShareCore

/// What the encoder actually emits, read back from the bitstream.
///
/// Every other check on this encoder asserts what we *asked* for — the
/// properties we set. This asserts what came out, which is the only way to
/// catch a request the encoder accepted and then ignored. P2.2 of the latency
/// research asked for exactly this, because low-latency mode selects a
/// different encoder and there is no guarantee it honours the same profile.
final class H264EncoderTests: XCTestCase {

    // MARK: - The specification

    /// The flag is an encoder *specification*, not a property. Getting that
    /// wrong is silent: `VTSessionSetProperty` would return an error nobody
    /// reads, and the session would run in the ordinary mode.
    func testTheSpecificationSelectsLowLatencyRateControl() throws {
        let spec = H264Encoder.lowLatencySpecification as NSDictionary
        let key = kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String
        XCTAssertEqual(
            spec[key] as? Bool, true,
            "the specification must ask for the low-latency encoder: \(spec)")
    }

    // MARK: - The bitstream

    /// Encodes a few frames and reads the parameter sets back out.
    func testAKeyframeCarriesItsParameterSetsInBand() throws {
        let encoder = H264Encoder(bitrate: 4_000_000)
        let frames = try encode(with: encoder, count: 6)

        XCTAssertFalse(frames.isEmpty, "the encoder produced nothing")
        guard let keyframe = frames.first(where: { $0.isKeyframe }) else {
            return XCTFail("no keyframe in \(frames.count) frames")
        }

        // SPEC §3.1: a keyframe begins with SPS and PPS so a receiver joining
        // mid-stream can configure its decoder from the stream alone. The
        // receiver derives its codec string from the SPS, so a keyframe without
        // one produces a decoder that never configures — and no picture.
        let types = naluTypes(in: keyframe.data)
        XCTAssertTrue(types.contains(7), "no SPS in the keyframe: \(types)")
        XCTAssertTrue(types.contains(8), "no PPS in the keyframe: \(types)")
        XCTAssertTrue(types.contains(5), "no IDR slice in the keyframe: \(types)")

        if let sps = types.firstIndex(of: 7), let idr = types.firstIndex(of: 5) {
            XCTAssertLessThan(sps, idr, "SPS must precede the IDR it describes")
        }
    }

    /// The read-back that motivated this test. We ask for High profile because
    /// CABAC and the 8x8 transform matter for the sharp text and flat regions
    /// screen content is made of. Low-latency mode selects a different encoder,
    /// so whether it honours that request is a question the properties cannot
    /// answer — only the emitted SPS can.
    func testTheEmittedProfileIsTheOneWeAskedFor() throws {
        let encoder = H264Encoder(bitrate: 4_000_000)
        let frames = try encode(with: encoder, count: 6)

        guard let keyframe = frames.first(where: { $0.isKeyframe }),
            let profile = profileIDC(in: keyframe.data)
        else {
            return XCTFail("could not read a profile from the emitted SPS")
        }

        print(
            "[encoder] lowLatency=\(encoder.lowLatencyRateControl)"
                + " profile_idc=\(profile) frames=\(frames.count)")

        // 100 is High. 77 is Main, 66 is Baseline — either would mean the
        // encoder quietly downgraded us and the assumption in P2.2 is wrong.
        XCTAssertEqual(
            profile, 100,
            "asked for High (100) and the stream says \(profile) — the "
                + "low-latency encoder does not honour the requested profile")
    }

    /// Not asserted as true: whether a low-latency encoder exists is a property
    /// of the machine, and the fallback is deliberate. What must hold is that a
    /// session starts either way and reports honestly which one it got, so a
    /// build silently running the ordinary encoder is diagnosable.
    func testASessionStartsWhicheverEncoderIsAvailable() throws {
        let encoder = H264Encoder(bitrate: 4_000_000)
        XCTAssertNoThrow(try encoder.start(width: 640, height: 480, fps: 30))
        defer { encoder.stop() }
        print("[encoder] low-latency rate control granted: \(encoder.lowLatencyRateControl)")
    }

    /// The one that catches a dropped specification.
    ///
    /// `lowLatencyRateControl` is inferred from "creation with the
    /// specification succeeded", and an inference cannot notice if the
    /// specification stops being passed — revert `start()` to
    /// `encoderSpecification: nil` and the flag still reports true. The encoder
    /// identifier can notice, because VideoToolbox instantiates a genuinely
    /// different encoder for each.
    ///
    /// The ordinary identifier is not written down here. Apple is free to
    /// rename either encoder; what must hold is that they are *not the same
    /// one*, so the comparison is against a plain session built right here.
    func testTheGrantedEncoderIsNotTheOrdinaryOne() throws {
        let encoder = H264Encoder(bitrate: 4_000_000)
        try encoder.start(width: 640, height: 480, fps: 30)
        defer { encoder.stop() }

        guard encoder.lowLatencyRateControl else {
            // The fallback is legitimate: this machine has no low-latency
            // encoder. Nothing to compare, and failing here would only assert
            // what hardware the test is running on.
            return print("[encoder] no low-latency encoder on this machine — comparison skipped")
        }

        var plain: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: 640, height: 480,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &plain)
        guard status == noErr, let plain else {
            return XCTFail("could not create an ordinary session to compare against: \(status)")
        }
        defer { VTCompressionSessionInvalidate(plain) }

        var identifier: CFTypeRef?
        VTSessionCopyProperty(
            plain, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &identifier)
        let ordinary = identifier as? String

        print("[encoder] granted=\(encoder.encoderID ?? "nil") ordinary=\(ordinary ?? "nil")")
        XCTAssertNotNil(encoder.encoderID, "the session did not report an encoder identifier")
        XCTAssertNotEqual(
            encoder.encoderID, ordinary,
            "the encoder reports low-latency rate control but VideoToolbox handed us the same "
                + "encoder as an unspecified session — the specification is not reaching "
                + "VTCompressionSessionCreate")
    }

    // MARK: - Helpers

    private func encode(with encoder: H264Encoder, count: Int) throws -> [H264Encoder.EncodedFrame] {
        let produced = NSLock()
        var frames: [H264Encoder.EncodedFrame] = []
        encoder.onEncodedFrame = { frame in
            produced.lock()
            frames.append(frame)
            produced.unlock()
        }

        try encoder.start(width: 640, height: 480, fps: 30)
        // Idempotent, and only reached if `encode` throws part-way through.
        defer { encoder.stop() }

        for index in 0..<count {
            // Vary the content so later frames are not trivially empty — an
            // encoder fed identical frames can emit almost nothing.
            let buffer = try pixelBuffer(width: 640, height: 480, fill: UInt8(40 + index * 20))
            try encoder.encode(
                buffer, presentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }

        // `stop()` calls VTCompressionSessionCompleteFrames, which blocks until
        // every queued frame has been emitted. That is a real barrier, so this
        // needs no sleep and no deadline — the result is the same on a fast
        // machine and a loaded CI runner. Three rounds of CI failures on the
        // send-gate tests came from measuring the runner instead of the code;
        // there is no reason to repeat it here when the API offers a barrier.
        encoder.stop()

        produced.lock(); defer { produced.unlock() }
        return frames
    }

    private func pixelBuffer(width: Int, height: Int, fill: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes =
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard status == kCVReturnSuccess, let created = buffer else {
            throw NSError(domain: "test", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(created, [])
        if let base = CVPixelBufferGetBaseAddress(created) {
            memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(created) * height)
        }
        CVPixelBufferUnlockBaseAddress(created, [])
        return created
    }

    /// NALU types in an Annex-B buffer, in order. The encoder emits 4-byte
    /// start codes exclusively (see `H264Encoder`), so this does not need the
    /// 3-byte handling the receiver's parser has.
    private func naluTypes(in data: Data) -> [UInt8] {
        var types: [UInt8] = []
        var index = 0
        while index + 4 < data.count {
            if data[index] == 0, data[index + 1] == 0, data[index + 2] == 0, data[index + 3] == 1 {
                types.append(data[index + 4] & 0x1F)
                index += 5
            } else {
                index += 1
            }
        }
        return types
    }

    /// `profile_idc` is the byte immediately after the SPS NAL header.
    private func profileIDC(in data: Data) -> UInt8? {
        var index = 0
        while index + 5 < data.count {
            if data[index] == 0, data[index + 1] == 0, data[index + 2] == 0, data[index + 3] == 1,
                data[index + 4] & 0x1F == 7
            {
                return data[index + 5]
            }
            index += 1
        }
        return nil
    }
}
