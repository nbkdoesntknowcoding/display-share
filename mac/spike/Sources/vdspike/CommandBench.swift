import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

/// Task 0.3 — Measure baseline capture cost.
///
/// Reports achieved frame rate, frame-interval distribution and CPU cost at a
/// given target fps, and confirms the 60 Hz ceiling by asking for more.
///
/// CPU is reported two ways on purpose: this process's own usage (what our
/// capture loop costs) and system-wide busy time (which also catches the
/// WindowServer compositing work our virtual display causes). Reporting only
/// the former would understate the true cost of the feature.
final class BenchProbe: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var frameTimes: [CFAbsoluteTime] = []
    private(set) var idleFrames = 0
    private(set) var streamError: Error?
    private let lock = NSLock()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw),
            status != .complete
        {
            lock.lock(); idleFrames += 1; lock.unlock()
            return
        }
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); frameTimes.append(now); lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { streamError = error }

    var snapshot: (times: [CFAbsoluteTime], idle: Int) {
        lock.lock(); defer { lock.unlock() }
        return (frameTimes, idleFrames)
    }
}

/// Process CPU seconds consumed so far (user + system).
private func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return user + sys
}

/// System-wide cumulative CPU ticks (user, system, idle, nice).
private func systemCPUTicks() -> (busy: Double, total: Double) {
    var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    var info = host_cpu_load_info_data_t()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    let user = Double(info.cpu_ticks.0)
    let system = Double(info.cpu_ticks.1)
    let idle = Double(info.cpu_ticks.2)
    let nice = Double(info.cpu_ticks.3)
    let busy = user + system + nice
    return (busy, busy + idle)
}

private struct BenchResult {
    var requestedFPS: Int
    var achievedFPS: Double
    var completeFrames: Int
    var idleFrames: Int
    var meanIntervalMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var maxIntervalMs: Double
    var processCPUPercent: Double
    var systemCPUPercent: Double
}

/// `capture: false` runs the identical scenario (virtual display + animated
/// content) WITHOUT a capture stream. Subtracting it from the capture run is
/// the only way to attribute cost to capture rather than to unrelated machine
/// load or to the animation itself.
private func runOne(fps: Int, seconds: Double, width: UInt32, height: UInt32, capture: Bool = true) -> BenchResult? {
    var config = VirtualDisplayHost.Configuration()
    config.width = width
    config.height = height
    config.refreshRate = Double(fps)
    config.hiDPI = false
    config.name = "Display Share (Bench)"

    let host = VirtualDisplayHost(config: config)
    guard let displayID = try? host.start() else {
        print("  ❌ could not create virtual display")
        return nil
    }
    defer { host.stop() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))

    let animator = AnimatedContent()
    animator.start(on: displayID)
    defer { animator.stop() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

    if !capture {
        // Same scene, no capture stream: pure baseline.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let cpuStart = processCPUSeconds()
        let sysStart = systemCPUTicks()
        let wallStart = CFAbsoluteTimeGetCurrent()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let wall = CFAbsoluteTimeGetCurrent() - wallStart
        let cpuUsed = processCPUSeconds() - cpuStart
        let sysEnd = systemCPUTicks()
        let sysBusy = sysEnd.busy - sysStart.busy
        let sysTotal = sysEnd.total - sysStart.total
        return BenchResult(
            requestedFPS: fps, achievedFPS: 0, completeFrames: 0, idleFrames: 0,
            meanIntervalMs: 0, p50Ms: 0, p95Ms: 0, maxIntervalMs: 0,
            processCPUPercent: wall > 0 ? cpuUsed / wall * 100 : 0,
            systemCPUPercent: sysTotal > 0 ? sysBusy / sysTotal * 100 : 0)
    }

    var shareable: SCShareableContent?
    let sem = DispatchSemaphore(value: 0)
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
        shareable = content
        sem.signal()
    }
    guard sem.wait(timeout: .now() + 10) == .success,
        let target = shareable?.displays.first(where: { $0.displayID == displayID })
    else {
        print("  ❌ ScreenCaptureKit could not see the display")
        return nil
    }

    let streamConfig = SCStreamConfiguration()
    streamConfig.width = target.width
    streamConfig.height = target.height
    streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
    streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    streamConfig.queueDepth = 6
    streamConfig.showsCursor = true

    let probe = BenchProbe()
    let stream = SCStream(
        filter: SCContentFilter(display: target, excludingWindows: []),
        configuration: streamConfig, delegate: probe)
    try? stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: DispatchQueue(label: "bench"))

    let startSem = DispatchSemaphore(value: 0)
    stream.startCapture { _ in startSem.signal() }
    _ = startSem.wait(timeout: .now() + 10)

    // Warm up before measuring so first-frame allocation is excluded.
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    let baselineFrames = probe.snapshot.times.count
    let baselineIdle = probe.snapshot.idle
    let cpuStart = processCPUSeconds()
    let sysStart = systemCPUTicks()
    let wallStart = CFAbsoluteTimeGetCurrent()

    RunLoop.current.run(until: Date().addingTimeInterval(seconds))

    let wall = CFAbsoluteTimeGetCurrent() - wallStart
    let cpuUsed = processCPUSeconds() - cpuStart
    let sysEnd = systemCPUTicks()
    let sysBusy = sysEnd.busy - sysStart.busy
    let sysTotal = sysEnd.total - sysStart.total

    let stopSem = DispatchSemaphore(value: 0)
    stream.stopCapture { _ in stopSem.signal() }
    _ = stopSem.wait(timeout: .now() + 5)

    let snap = probe.snapshot
    let window = Array(snap.times.dropFirst(baselineFrames))
    guard window.count > 2 else {
        print("  ❌ too few frames to measure")
        return nil
    }
    var intervals: [Double] = []
    for i in 1..<window.count { intervals.append((window[i] - window[i - 1]) * 1000) }
    let sorted = intervals.sorted()

    return BenchResult(
        requestedFPS: fps,
        achievedFPS: Double(window.count - 1) / (window.last! - window.first!),
        completeFrames: window.count,
        idleFrames: snap.idle - baselineIdle,
        meanIntervalMs: intervals.reduce(0, +) / Double(intervals.count),
        p50Ms: sorted[sorted.count / 2],
        p95Ms: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
        maxIntervalMs: sorted.last ?? 0,
        processCPUPercent: wall > 0 ? cpuUsed / wall * 100 : 0,
        systemCPUPercent: sysTotal > 0 ? sysBusy / sysTotal * 100 : 0)
}

func runBench(_ args: Args) {
    let seconds = args.double("seconds", 10)
    let width = UInt32(args.int("width", 1920))
    let height = UInt32(args.int("height", 1080))
    let rates = args.string("rates", "30,60,120").split(separator: ",").compactMap { Int($0) }

    print("=== Task 0.3 — Baseline capture cost ===")
    print("host: \(hostInfo())")
    print("resolution: \(width)x\(height), \(Int(seconds))s per rate, animated content driving every frame\n")

    if !CGPreflightScreenCaptureAccess() {
        print("❌ Screen Recording permission required.")
        exit(1)
    }

    if args.bool("baseline", false) {
        print("--- baseline: virtual display + animation, NO capture ---")
        if let b = runOne(fps: 60, seconds: seconds, width: width, height: height, capture: false) {
            print(String(format: "  CPU: this process %.1f%%  |  system-wide busy %.1f%%", b.processCPUPercent, b.systemCPUPercent))
        }
        print("")
        exit(0)
    }

    var results: [BenchResult] = []
    for fps in rates {
        print("--- target \(fps) fps ---")
        if let r = runOne(fps: fps, seconds: seconds, width: width, height: height) {
            results.append(r)
            print(String(format: "  achieved %.1f fps over %d frames (%d idle)", r.achievedFPS, r.completeFrames, r.idleFrames))
            print(String(format: "  interval mean %.2fms  p50 %.2fms  p95 %.2fms  max %.2fms", r.meanIntervalMs, r.p50Ms, r.p95Ms, r.maxIntervalMs))
            print(String(format: "  CPU: this process %.1f%%  |  system-wide busy %.1f%%", r.processCPUPercent, r.systemCPUPercent))
        }
        print("")
    }

    guard !results.isEmpty else {
        print("VERDICT: NO-GO — no measurements collected.")
        exit(1)
    }

    print("--- summary ---")
    print(String(format: "%-10s %-12s %-12s %-10s %-12s", ("target" as NSString).utf8String!, ("achieved" as NSString).utf8String!, ("p95 ms" as NSString).utf8String!, ("proc CPU" as NSString).utf8String!, ("sys CPU" as NSString).utf8String!))
    for r in results {
        print(String(format: "%-10@ %-12@ %-12@ %-10@ %-12@",
            "\(r.requestedFPS)" as NSString,
            String(format: "%.1f fps", r.achievedFPS) as NSString,
            String(format: "%.2f", r.p95Ms) as NSString,
            String(format: "%.1f%%", r.processCPUPercent) as NSString,
            String(format: "%.1f%%", r.systemCPUPercent) as NSString))
    }

    // 60 Hz ceiling: asking for more than 60 must not deliver more than ~60.
    if let over = results.first(where: { $0.requestedFPS > 60 }) {
        let capped = over.achievedFPS <= 65
        print("\n  \(capped ? "✅" : "❌") 60Hz ceiling confirmed: requested \(over.requestedFPS)fps, achieved \(String(format: "%.1f", over.achievedFPS))fps")
    }

    let sixty = results.first { $0.requestedFPS == 60 }
    if let sixty {
        let healthy = sixty.achievedFPS >= 50
        print("  \(healthy ? "✅" : "❌") sustains ~60fps at \(width)x\(height) (\(String(format: "%.1f", sixty.achievedFPS)) fps)")
        print("\nVERDICT: \(healthy ? "GO ✅ — capture cost is well within budget for the product." : "INVESTIGATE ⚠️")")
        exit(healthy ? 0 : 1)
    }
    exit(0)
}
