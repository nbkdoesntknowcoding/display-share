import CoreMedia
import CoreVideo
import DisplayShareCore
import Foundation

/// Task 2.1 acceptance: dump a raw Annex-B elementary stream so an independent
/// decoder can confirm it is valid.
func runH264Dump(displayID: UInt32, seconds: Double, fps: Int, bitrate: Int, path: String) {
    let session = CaptureSession(
        configuration: .init(
            displayID: displayID, fps: fps,
            // NV12 is VideoToolbox's native input; BGRA would force a colour
            // conversion on every frame.
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
    let encoder = H264Encoder(bitrate: bitrate)

    FileManager.default.createFile(atPath: path, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: path) else {
        print("❌ cannot write \(path)")
        return
    }

    let writeLock = NSLock()
    encoder.onEncodedFrame = { frame in
        writeLock.lock()
        handle.write(frame.data)
        writeLock.unlock()
    }

    do {
        try session.start()
        try encoder.start(
            width: Int32(session.pixelSize.width), height: Int32(session.pixelSize.height), fps: fps)
    } catch {
        print("❌ start failed: \(error)")
        return
    }

    // Which encoder we actually got. The low-latency one is selected by an
    // encoder specification, so it can be refused silently — and a build
    // running the ordinary encoder looks identical from the outside.
    print("low latency    : \(encoder.lowLatencyRateControl ? "yes" : "no (ordinary encoder)")")
    print("encoder        : \(encoder.encoderID ?? "unreported")")

    // First frame must be an IDR so the file is decodable from byte zero.
    encoder.requestKeyframe()

    var frameIndex: Int64 = 0
    let stopAt = Date().addingTimeInterval(seconds)
    let worker = Thread {
        while Date() < stopAt {
            guard let pixels = session.frames.dequeue(timeout: 0.5) else { continue }
            let pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
            frameIndex += 1
            try? encoder.encode(pixels, presentationTime: pts)
        }
    }
    worker.start()
    while Date() < stopAt { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    session.stop()
    encoder.stop()
    Thread.sleep(forTimeInterval: 0.5)
    try? handle.close()

    let stats = encoder.statistics
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    print("frames encoded : \(stats.framesEncoded)  (keyframes \(stats.keyframes))")
    print(String(format: "encode time    : %.2f ms avg, %.2f ms last",
                 stats.averageEncodeMillis, stats.lastEncodeMillis))
    print("bytes produced : \(stats.bytesProduced)")
    print("file           : \(path) (\(size ?? 0) bytes)")
    if stats.framesEncoded > 0 {
        let mbps = Double(stats.bytesProduced) * 8 / seconds / 1_000_000
        print(String(format: "bitrate        : %.2f Mbps at %.1f fps",
                     mbps, Double(stats.framesEncoded) / seconds))
    }
}
