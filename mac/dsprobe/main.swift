import CoreGraphics
import DisplayShareCore
import Foundation

// dsprobe — Task 1.2 acceptance harness.
//
// Drives a real CaptureSession against a real virtual display (created through
// vd_helper) and reports achieved fps and drop behaviour, with a fast consumer
// and again with a deliberately slow one. Proves both halves of the acceptance:
// "emits CVPixelBuffers at the configured fps" and "with a documented drop
// policy under load".

func measure(fps: Int, consumerDelayMs: Int, seconds: Double, displayID: CGDirectDisplayID) {
    let session = CaptureSession(
        configuration: .init(displayID: displayID, fps: fps, queueDepth: 2))
    do {
        try session.start()
    } catch {
        print("  ❌ capture failed: \(error)")
        return
    }

    var consumed = 0
    var firstFrame: CFAbsoluteTime?
    var lastFrame: CFAbsoluteTime?
    let stopAt = Date().addingTimeInterval(seconds)

    let consumer = Thread {
        while Date() < stopAt {
            guard session.frames.dequeue(timeout: 0.5) != nil else { continue }
            let now = CFAbsoluteTimeGetCurrent()
            if firstFrame == nil { firstFrame = now }
            lastFrame = now
            consumed += 1
            if consumerDelayMs > 0 {
                Thread.sleep(forTimeInterval: Double(consumerDelayMs) / 1000.0)
            }
        }
    }
    consumer.start()
    while Date() < stopAt { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    session.stop()
    Thread.sleep(forTimeInterval: 0.3)

    let stats = session.frames.statistics
    let achieved: Double = {
        guard let f = firstFrame, let l = lastFrame, consumed > 1, l > f else { return 0 }
        return Double(consumed - 1) / (l - f)
    }()

    print("  target \(fps)fps, consumer delay \(consumerDelayMs)ms")
    print(String(format: "    captured %d  delivered %d  droppedOldest %d  (drop rate %.1f%%)",
                 stats.enqueued, stats.delivered, stats.droppedOldest, stats.dropRate * 100))
    print(String(format: "    consumer saw %.1f fps, capture enqueued %.1f fps, idle frames %d",
                 achieved, Double(stats.enqueued) / seconds, session.idleFrames))
    print("    queue depth never exceeded \(stats.highWaterMark) (capacity 2)")
}

let fps = Int(ProcessInfo.processInfo.environment["DS_FPS"] ?? "60") ?? 60
let seconds = Double(ProcessInfo.processInfo.environment["DS_SECONDS"] ?? "6") ?? 6

// Content-only mode: animate on an EXISTING display (created by the app) so the
// full app pipeline can be exercised end to end. Used by the Task 1.3 check.
if let raw = ProcessInfo.processInfo.environment["DS_CONTENT_DISPLAY"],
   let target = UInt32(raw.hasPrefix("0x") ? String(raw.dropFirst(2)) : raw, radix: raw.hasPrefix("0x") ? 16 : 10) {
    let seconds = Double(ProcessInfo.processInfo.environment["DS_SECONDS"] ?? "20") ?? 20
    print("animating content on display 0x\(String(target, radix: 16)) for \(seconds)s")
    let content = AnimatedContent()
    content.start(on: target)
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    content.stop()
    exit(0)
}

// H.264 dump mode (Task 2.1): creates its own display, animates it, encodes.
if let dumpPath = ProcessInfo.processInfo.environment["DS_H264_DUMP"] {
    let seconds = Double(ProcessInfo.processInfo.environment["DS_SECONDS"] ?? "6") ?? 6
    let fps = Int(ProcessInfo.processInfo.environment["DS_FPS"] ?? "60") ?? 60
    let bitrate = Int(ProcessInfo.processInfo.environment["DS_BITRATE"] ?? "12000000") ?? 12_000_000
    let client = HelperClient()
    try! client.connect()
    var cfg = DisplayConfiguration()
    cfg.name = "Display Share (H264 Probe)"
    cfg.refreshRate = Double(fps)
    let id = try! client.createDisplay(cfg)
    print("=== Task 2.1 — VideoToolbox H.264 ===")
    print("display 0x\(String(id, radix: 16)) \(cfg.width)x\(cfg.height) @ \(fps)fps, target \(bitrate / 1_000_000) Mbps")
    Thread.sleep(forTimeInterval: 1.0)
    let content = AnimatedContent()
    content.start(on: id)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    runH264Dump(displayID: id, seconds: seconds, fps: fps, bitrate: bitrate, path: dumpPath)
    content.stop()
    client.shutdown()
    exit(0)
}

print("=== Task 1.2 — CaptureSession acceptance ===")

let client = HelperClient()
do {
    try client.connect()
} catch {
    print("❌ could not reach vd_helper: \(error)")
    print("   (set DS_HELPER_PATH to the built vd_helper binary)")
    exit(1)
}

var config = DisplayConfiguration()
config.name = "Display Share (Probe)"
config.refreshRate = Double(fps)

let displayID: UInt32
do {
    displayID = try client.createDisplay(config)
} catch {
    print("❌ could not create display: \(error)")
    exit(1)
}
print("virtual display 0x\(String(displayID, radix: 16)) at \(config.width)x\(config.height)\n")

// Give the window server a beat, then drive real change on the display.
// Without this the desktop is idle and SCK emits .idle rather than pixels.
Thread.sleep(forTimeInterval: 1.0)
let animator = AnimatedContent()
animator.start(on: displayID)
RunLoop.current.run(until: Date().addingTimeInterval(0.5))

print("--- fast consumer (keeps up) ---")
measure(fps: fps, consumerDelayMs: 0, seconds: seconds, displayID: displayID)

print("\n--- slow consumer (100ms per frame — forces back-pressure) ---")
measure(fps: fps, consumerDelayMs: 100, seconds: seconds, displayID: displayID)

animator.stop()
client.shutdown()
print("\ndone.")
