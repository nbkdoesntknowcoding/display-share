import CoreMedia
import CoreVideo
import XCTest

@testable import DisplayShareCore

/// Task 8.2 acceptance, exercised locally: a real H.264 stream must decode.
///
/// The stream is produced by the project's OWN encoder rather than a checked-in
/// fixture, so the test covers the actual Annex-B shape VideoToolbox emits. It
/// cannot cover the Windows encoder's mixed start codes — `AnnexBTests` does
/// that on synthetic payloads, because generating a Media Foundation stream
/// requires Windows.
final class VideoDecoderTests: XCTestCase {

    private func makePixelBuffer(width: Int, height: Int, tick: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        )
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            // A moving block. A flat colour compresses to nearly nothing and
            // would leave inter prediction untested.
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    let inBlock = x >= (tick * 7) % max(width - 64, 1)
                        && x < (tick * 7) % max(width - 64, 1) + 64
                        && y > height / 3 && y < height / 2
                    bytes[offset] = inBlock ? 220 : 16
                    bytes[offset + 1] = inBlock ? 200 : 16
                    bytes[offset + 2] = inBlock ? 40 : 16
                    bytes[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    /// Encodes a short clip and returns the access units in order.
    private func encodeClip(width: Int32, height: Int32, frames: Int) throws -> [WireProtocol.VideoMessage] {
        let encoder = H264Encoder(bitrate: 2_000_000)
        let collected = NSMutableArray()
        let lock = NSLock()
        encoder.onEncodedFrame = { frame in
            lock.lock()
            collected.add(
                WireProtocol.VideoMessage(
                    isKeyframe: frame.isKeyframe,
                    timestampMicros: UInt64(max(0, frame.presentationTime.seconds) * 1_000_000),
                    payload: frame.data
                )
            )
            lock.unlock()
        }
        try encoder.start(width: width, height: height, fps: 30)
        for index in 0..<frames {
            let pixelBuffer = makePixelBuffer(width: Int(width), height: Int(height), tick: index)
            try encoder.encode(
                pixelBuffer,
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 30)
            )
        }
        // stop() drains the compression session, so everything queued is out.
        encoder.stop()

        lock.lock()
        defer { lock.unlock() }
        return collected.compactMap { $0 as? WireProtocol.VideoMessage }
    }

    func testEncodedStreamDecodesBackToPixels() throws {
        let messages = try encodeClip(width: 640, height: 360, frames: 12)
        XCTAssertFalse(messages.isEmpty, "the encoder produced nothing to decode")
        XCTAssertTrue(messages.first?.isKeyframe == true, "a clip must open on a keyframe")

        let decoder = VideoDecoder()
        var decodedFrames = 0
        for message in messages {
            if try decoder.decode(message) != nil { decodedFrames += 1 }
        }

        XCTAssertGreaterThan(decodedFrames, 0, "nothing decoded")
        XCTAssertEqual(decoder.stats.width, 640)
        XCTAssertEqual(decoder.stats.height, 360)
        XCTAssertEqual(decoder.stats.decodeFailures, 0)
        // The HUD reads this; an empty or "waiting" value once frames are
        // flowing would be a reporting bug.
        XCTAssertTrue(
            decoder.stats.decodePath.hasPrefix("VideoToolbox"),
            "unexpected decode path: \(decoder.stats.decodePath)"
        )
    }

    func testDeltaFramesBeforeAKeyframeAreSkippedNotFailed() throws {
        // A viewer connecting mid-stream sees deltas first. Those must be
        // skipped quietly; counting them as failures would make a normal
        // connection look broken.
        let messages = try encodeClip(width: 320, height: 240, frames: 8)
        let deltas = messages.filter { !$0.isKeyframe }
        try XCTSkipIf(deltas.isEmpty, "encoder produced only keyframes")

        let decoder = VideoDecoder()
        for message in deltas.prefix(3) {
            XCTAssertNil(try decoder.decode(message))
        }
        XCTAssertEqual(decoder.stats.decodeFailures, 0)
        XCTAssertEqual(decoder.stats.framesSkipped, min(3, deltas.count))
        XCTAssertEqual(decoder.stats.decodePath, "waiting for keyframe")
    }
}
