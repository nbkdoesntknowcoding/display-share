import AppKit
import CoreGraphics
import Foundation

/// Task 0.1 — Verify CGVirtualDisplay on target hardware.
///
/// Proves, without relying on the private API's own return values:
///   1. a new display ID appears in CGGetActiveDisplayList that was not there before
///   2. it reports the geometry we asked for
///   3. it disappears again when the owning process releases it
func runCreate(_ args: Args) {
    var config = VirtualDisplayHost.Configuration()
    config.width = UInt32(args.int("width", 1920))
    config.height = UInt32(args.int("height", 1080))
    config.refreshRate = args.double("fps", 60)
    config.hiDPI = args.bool("hidpi", true)
    config.diagonalInches = args.double("diagonal", 15.6)
    config.name = args.string("name", "Display Share (Spike)")
    let duration = args.double("duration", 0)

    print("=== Task 0.1 — CGVirtualDisplay feasibility ===")
    print("host: \(hostInfo())")
    print(
        "request: \(config.width)x\(config.height) @ \(config.refreshRate)Hz, hiDPI=\(config.hiDPI), \(config.diagonalInches)\" panel"
    )

    // Register BEFORE any mode query, so CoreGraphics refreshes its per-process
    // display cache when the virtual display arrives.
    // Hypothesis under test: CG reconfiguration notifications are only delivered
    // to processes connected to the window server as an application. A bare CLI
    // never gets them, so its cached mode table goes permanently stale.
    if args.bool("gui", false) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        print("(NSApplication initialised — process promoted to a GUI app)")
    }

    // NOTE: defaults to OFF. Registering a reconfiguration callback in a process
    // that cannot service the notification permanently freezes CoreGraphics'
    // view of the display set — CGDisplayCopyDisplayMode then returns nil for
    // the new display forever. See docs/phase0-findings.md.
    let watcher = ReconfigurationWatcher()
    if args.bool("watch", false) { watcher.start() }

    let before = Set(DisplayInventory.activeDisplayIDs())
    print("\n--- displays BEFORE (\(before.count)) ---")
    // --cold-cache avoids calling CGDisplayCopyDisplayMode before the virtual
    // display is created, to test whether the first mode query in a process
    // permanently freezes CoreGraphics' view of the display set.
    // Defaults ON: any mode query made before the virtual display exists
    // snapshots the display set for the lifetime of this process.
    if args.bool("cold-cache", true) {
        print("  (mode queries suppressed: \(before.map { "0x" + String($0, radix: 16) }.joined(separator: ", ")))")
    } else {
        for id in before.sorted() { print(DisplayInventory.describe(id)) }
    }

    let host = VirtualDisplayHost(config: config)
    var terminatedBySystem = false

    let displayID: CGDirectDisplayID
    do {
        displayID = try host.start { terminatedBySystem = true }
    } catch {
        print("\n❌ FAIL: \(error)")
        print("\nVERDICT: NO-GO — CGVirtualDisplay is not usable on this system.")
        exit(1)
    }

    // The display joins the active list before the window server finishes
    // publishing its mode table. Measure how long that lag actually is — later
    // phases must not query geometry until it has settled.
    // If the first mode query in a process snapshots the display set, then
    // querying too early poisons it permanently. Wait *without querying* first.
    let firstQueryDelay = args.double("first-query-delay", 0)
    if firstQueryDelay > 0 {
        print(String(format: "\n(waiting %.2fs before the FIRST mode query)", firstQueryDelay))
        RunLoop.current.run(until: Date().addingTimeInterval(firstQueryDelay))
    }

    let settleStart = Date()
    var settleSeconds: Double? = nil
    print("\n--- mode-table settle poll ---")
    var nextReport = 0.0
    while Date().timeIntervalSince(settleStart) < 5.0 {
        let elapsed = Date().timeIntervalSince(settleStart)
        let cur = CGDisplayCopyDisplayMode(displayID)
        if elapsed >= nextReport {
            let allNil = (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode])?.count ?? 0
            print(
                String(
                    format: "  t=%5.2fs  current=%@  allModes(nil opts)=%d",
                    elapsed, cur == nil ? "nil" : "ok", allNil))
            nextReport = elapsed + 0.5
        }
        if cur != nil {
            settleSeconds = elapsed
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    if let s = settleSeconds {
        print(String(format: "mode table settled %.0f ms after the display went active", s * 1000))
    } else {
        print("⚠️  mode table never appeared within 5s")
    }
    print("--- reconfiguration events observed ---")
    print(watcher.summary)

    let after = Set(DisplayInventory.activeDisplayIDs())
    let added = after.subtracting(before)

    print("\n--- displays AFTER (\(after.count)) ---")
    for id in after.sorted() { print(DisplayInventory.describe(id)) }

    print("\n--- new display(s): \(added.map { "0x" + String($0, radix: 16) }.joined(separator: ", ")) ---")
    guard added.contains(displayID) else {
        print("❌ FAIL: reported displayID 0x\(String(displayID, radix: 16)) is not among the newly added displays.")
        exit(1)
    }

    print("\n--- modes offered for the virtual display ---")
    print(DisplayInventory.describeModes(displayID))

    // Geometry check: macOS should report the pixel dimensions we asked for.
    let pixelsWide = CGDisplayPixelsWide(displayID)
    let bounds = CGDisplayBounds(displayID)
    var checks: [(String, Bool)] = []
    checks.append(("new display ID appeared", true))
    checks.append(("display is online", CGDisplayIsOnline(displayID) != 0))
    checks.append(("display is active", CGDisplayIsActive(displayID) != 0))
    checks.append(("display is NOT builtin", CGDisplayIsBuiltin(displayID) == 0))
    // Measured, not assumed: points come from CGDisplayBounds, pixels from
    // CGDisplayPixelsWide. Their ratio IS the backing scale.
    let backingScale = Double(pixelsWide) / Double(max(bounds.width, 1))
    let expectedScale: Double = config.hiDPI ? 2.0 : 1.0
    print("\n--- geometry ---")
    print("  requested   : \(config.width)x\(config.height) pt, hiDPI=\(config.hiDPI)")
    print("  points      : \(Int(bounds.width))x\(Int(bounds.height))")
    print("  pixels      : \(pixelsWide)x\(CGDisplayPixelsHigh(displayID))")
    print("  backing scale: \(String(format: "%.2f", backingScale))x (expected \(String(format: "%.1f", expectedScale))x)")

    // kCGDisplayShowDuplicateLowResolutionModes is required: without it CG hides
    // the 2x HiDPI variant of a resolution as a "duplicate" of the 1x entry.
    let modeOptions = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue!] as CFDictionary
    let offered = (CGDisplayCopyAllDisplayModes(displayID, modeOptions) as? [CGDisplayMode]) ?? []
    checks.append(("logical size matches request", Int(bounds.width) == Int(config.width) && Int(bounds.height) == Int(config.height)))
    checks.append(("mode enumeration works", CGDisplayCopyDisplayMode(displayID) != nil))

    // macOS adopts the 1x mode by default even when a 2x mode is available, so
    // the meaningful assertion is that the HiDPI mode is *offered* — selecting
    // it is an explicit CGDisplaySetDisplayMode call (see findings doc).
    if config.hiDPI {
        let hasRetinaMode = offered.contains { $0.pixelWidth == $0.width * 2 && $0.width == Int(config.width) }
        checks.append(("a 2x HiDPI mode is offered at \(config.width)x\(config.height)", hasRetinaMode))
        print("  note: adopted mode is \(String(format: "%.2f", backingScale))x; a \(String(format: "%.1f", expectedScale))x mode is \(hasRetinaMode ? "available" : "NOT available") for explicit selection")
    } else {
        checks.append(("backing scale is 1.0x", abs(backingScale - 1.0) < 0.01))
    }

    // Empirically confirm the 60 Hz API ceiling claimed in the research doc.
    let maxHz = offered.map(\.refreshRate).max() ?? 0
    print("  max refresh rate offered: \(String(format: "%.2f", maxHz)) Hz across \(offered.count) modes")
    checks.append(("refresh ceiling is 60 Hz", maxHz > 0 && maxHz <= 60.01))

    print("\n--- acceptance checks ---")
    for (name, ok) in checks { print("  \(ok ? "✅" : "❌") \(name)") }

    print(
        """

        The display is now LIVE. Open System Settings ▸ Displays — you should see
        "\(config.name)". Drag a window onto it to confirm it is a real desktop.
        """)

    if duration > 0 {
        print("Holding for \(duration)s ...")
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    } else {
        print("Holding until Ctrl-C ...")
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { CFRunLoopStop(CFRunLoopGetMain()) }
        src.resume()
        CFRunLoopRun()
    }

    // Teardown check: releasing the object must remove the display.
    print("\n--- teardown ---")
    host.stop()
    let deadline = Date().addingTimeInterval(3.0)
    var removed = false
    while Date() < deadline {
        if !DisplayInventory.activeDisplayIDs().contains(displayID) {
            removed = true
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    print("  \(removed ? "✅" : "❌") display removed cleanly on release")
    if terminatedBySystem { print("  ℹ️  terminationHandler fired (system-initiated teardown)") }

    let finalSet = Set(DisplayInventory.activeDisplayIDs())
    print("  \(finalSet == before ? "✅" : "❌") display list returned to its original state")

    let pass = removed && finalSet == before && checks.allSatisfy { $0.1 }
    print("\nVERDICT: \(pass ? "GO ✅ — CGVirtualDisplay works on this hardware." : "INVESTIGATE ⚠️ — see failures above.")")
    exit(pass ? 0 : 1)
}
