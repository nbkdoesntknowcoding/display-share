import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Task 0.2 — Verify ScreenCaptureKit can capture a virtual display.
///
/// Opens an SCStream with an SCContentFilter pinned to the virtual SCDisplay,
/// dumps frames as PNGs, and measures each frame so the "not black, not
/// duplicated" acceptance criterion is checked numerically.
final class CaptureProbe: NSObject, SCStreamOutput, SCStreamDelegate {

    private let outputDirectory: URL
    private let frameTarget: Int
    private let writePNGs: Bool

    private var previousSignature: [UInt8]?
    private(set) var collected: [FrameStats] = []
    private(set) var droppedOrIncomplete = 0
    private(set) var streamError: Error?

    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var firstFrameTime: CFAbsoluteTime?
    private var lastFrameTime: CFAbsoluteTime?

    init(outputDirectory: URL, frameTarget: Int, writePNGs: Bool) {
        self.outputDirectory = outputDirectory
        self.frameTarget = frameTarget
        self.writePNGs = writePNGs
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished else { return }

        // A frame arriving with a status other than .complete carries no new
        // pixels (idle screen, occluded, etc.) and must not be counted.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw),
            status != .complete
        {
            droppedOrIncomplete += 1
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            droppedOrIncomplete += 1
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if firstFrameTime == nil { firstFrameTime = now }
        lastFrameTime = now

        let (stats, signature) = FrameStats.compute(from: pixelBuffer, previous: previousSignature)
        previousSignature = signature
        collected.append(stats)

        if writePNGs {
            writePNG(pixelBuffer, index: collected.count - 1)
        }

        if collected.count >= frameTarget {
            finished = true
            done.signal()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error
        if !finished {
            finished = true
            done.signal()
        }
    }

    private func writePNG(_ pixelBuffer: CVPixelBuffer, index: Int) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let url = outputDirectory.appendingPathComponent(String(format: "frame-%03d.png", index))
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    func wait(timeout: TimeInterval) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }

    var measuredFPS: Double {
        guard let first = firstFrameTime, let last = lastFrameTime, collected.count > 1, last > first else { return 0 }
        return Double(collected.count - 1) / (last - first)
    }
}

func runCapture(_ args: Args) {
    let frames = args.int("frames", 100)
    let fps = args.int("fps", 60)
    let outPath = args.string("out", "./spike-frames")
    let writePNGs = args.bool("png", true)

    print("=== Task 0.2 — ScreenCaptureKit capture of a virtual display ===")
    print("host: \(hostInfo())")

    // --- Screen Recording permission -------------------------------------
    // A non-bundled CLI has no TCC identity of its own; it inherits the
    // responsible parent process (Terminal, or whatever launched it). The
    // shipping app gets its own entry — see Task 6.3 onboarding.
    let preflight = CGPreflightScreenCaptureAccess()
    print("\n--- screen recording permission ---")
    print("  CGPreflightScreenCaptureAccess: \(preflight ? "granted ✅" : "NOT granted ❌")")
    if !preflight {
        print("  requesting access (this raises the system prompt) ...")
        let granted = CGRequestScreenCaptureAccess()
        print("  CGRequestScreenCaptureAccess: \(granted)")
        if !granted {
            print("""

                ❌ Screen Recording permission is required.
                   Grant it to the parent process (Terminal / Claude Code) in
                   System Settings ▸ Privacy & Security ▸ Screen Recording,
                   then re-run. Permission persists across relaunch once granted.
                """)
            exit(1)
        }
    }

    // --- Create the virtual display --------------------------------------
    var config = VirtualDisplayHost.Configuration()
    config.width = UInt32(args.int("width", 1920))
    config.height = UInt32(args.int("height", 1080))
    config.refreshRate = Double(fps)
    config.hiDPI = args.bool("hidpi", false)
    config.name = "Display Share (Capture Spike)"

    let host = VirtualDisplayHost(config: config)
    let displayID: CGDirectDisplayID
    do {
        displayID = try host.start()
    } catch {
        print("\n❌ could not create virtual display: \(error)")
        exit(1)
    }
    print("\nvirtual display 0x\(String(displayID, radix: 16)) created (\(config.width)x\(config.height))")
    defer { host.stop() }

    // Let the window server publish the display before asking SCK about it.
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))

    // Optional animated content, so "did the capture track live updates?" is
    // answerable. Without it an idle desktop yields only .idle frames.
    let animator = AnimatedContent()
    if args.bool("animate", true) {
        animator.start(on: displayID)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        print("animated content window placed at \(animator.frame.map(NSStringFromRect) ?? "?")")
    }
    defer { animator.stop() }

    // --- Find it in SCShareableContent ------------------------------------
    var shareable: SCShareableContent?
    var shareableError: Error?
    let contentSemaphore = DispatchSemaphore(value: 0)
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
        shareable = content
        shareableError = error
        contentSemaphore.signal()
    }
    guard contentSemaphore.wait(timeout: .now() + 10) == .success, let content = shareable else {
        print("\n❌ SCShareableContent failed: \(shareableError?.localizedDescription ?? "timeout")")
        exit(1)
    }

    print("\n--- displays visible to ScreenCaptureKit ---")
    for d in content.displays {
        let marker = d.displayID == displayID ? "  <-- our virtual display" : ""
        print("  0x\(String(d.displayID, radix: 16))  \(d.width)x\(d.height)\(marker)")
    }

    guard let target = content.displays.first(where: { $0.displayID == displayID }) else {
        print("\n❌ FAIL: ScreenCaptureKit does not see the virtual display.")
        print("VERDICT: NO-GO — capture of virtual displays is not possible this way.")
        exit(1)
    }
    print("✅ ScreenCaptureKit sees the virtual display")

    // --- Configure and start the stream ------------------------------------
    let outputDirectory = URL(fileURLWithPath: outPath)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let streamConfig = SCStreamConfiguration()
    streamConfig.width = target.width
    streamConfig.height = target.height
    // BGRA keeps the spike simple; the product uses NV12 into VideoToolbox.
    streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
    streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    streamConfig.queueDepth = 6
    streamConfig.showsCursor = true

    let filter = SCContentFilter(display: target, excludingWindows: [])
    let probe = CaptureProbe(outputDirectory: outputDirectory, frameTarget: frames, writePNGs: writePNGs)
    let stream = SCStream(filter: filter, configuration: streamConfig, delegate: probe)

    do {
        try stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
    } catch {
        print("\n❌ addStreamOutput failed: \(error)")
        exit(1)
    }

    print("\ncapturing \(frames) frames at \(fps)fps into \(outputDirectory.path) ...")
    let startSemaphore = DispatchSemaphore(value: 0)
    var startError: Error?
    stream.startCapture { error in
        startError = error
        startSemaphore.signal()
    }
    _ = startSemaphore.wait(timeout: .now() + 10)
    if let startError {
        print("\n❌ startCapture failed: \(startError)")
        print("VERDICT: NO-GO")
        exit(1)
    }

    // Pump the run loop while frames arrive on the capture queue.
    let deadline = Date().addingTimeInterval(Double(frames) / Double(fps) + 20)
    while probe.collected.count < frames && Date() < deadline && probe.streamError == nil {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    let stopSemaphore = DispatchSemaphore(value: 0)
    stream.stopCapture { _ in stopSemaphore.signal() }
    _ = stopSemaphore.wait(timeout: .now() + 5)

    report(probe: probe, requested: frames, fps: fps, outputDirectory: outputDirectory, writePNGs: writePNGs)
}

private func report(
    probe: CaptureProbe, requested: Int, fps: Int, outputDirectory: URL, writePNGs: Bool
) {
    let stats = probe.collected
    print("\n--- capture results ---")
    print("  frames captured      : \(stats.count) / \(requested)")
    print("  incomplete/dropped   : \(probe.droppedOrIncomplete)")
    print(String(format: "  measured frame rate  : %.1f fps (requested %d)", probe.measuredFPS, fps))
    if let e = probe.streamError { print("  stream error         : \(e)") }

    guard !stats.isEmpty else {
        print("\n❌ FAIL: no frames captured.\nVERDICT: NO-GO")
        exit(1)
    }

    let meanLuma = stats.map(\.meanLuma).reduce(0, +) / Double(stats.count)
    let meanNonBlack = stats.map(\.nonBlackRatio).reduce(0, +) / Double(stats.count)
    let maxUniqueColors = stats.map(\.uniqueColors).max() ?? 0
    // Frame 0 has no predecessor, so measure change over frames 1...n.
    let diffs = stats.dropFirst().map(\.diffFromPrevious)
    let changedFrames = diffs.filter { $0 > 0.5 }.count

    print("\n--- pixel analysis ---")
    print(String(format: "  mean luma            : %.1f / 255", meanLuma))
    print(String(format: "  non-black pixel ratio: %.1f%%", meanNonBlack * 100))
    print("  max unique colours   : \(maxUniqueColors) (sampled grid)")
    print("  frames differing from previous: \(changedFrames) / \(diffs.count)")

    var checks: [(String, Bool)] = []
    checks.append(("captured the requested frame count", stats.count >= requested))
    checks.append(("frames are not black", meanLuma > 1.0 && meanNonBlack > 0.01))
    checks.append(("frames contain real image content (>16 colours)", maxUniqueColors > 16))

    print("\n--- acceptance checks ---")
    for (name, ok) in checks { print("  \(ok ? "✅" : "❌") \(name)") }

    if writePNGs {
        let written = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path))?
            .filter { $0.hasSuffix(".png") }.count ?? 0
        print("\n  \(written) PNGs written to \(outputDirectory.path)")
    }

    if changedFrames == 0 {
        print("""

            ⚠️  Every frame is identical. That is EXPECTED for an idle virtual
               desktop with nothing animating on it — ScreenCaptureKit resends
               the same surface. Re-run with content moving on the display to
               confirm live updates are tracked.
            """)
    }

    let pass = checks.allSatisfy { $0.1 }
    print("\nVERDICT: \(pass ? "GO ✅ — ScreenCaptureKit captures the virtual display." : "INVESTIGATE ⚠️")")
    exit(pass ? 0 : 1)
}
