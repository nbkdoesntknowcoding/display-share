import CoreGraphics
import Foundation

/// Task 0.1 (supporting) — empirically map how CGVirtualDisplaySettings
/// parameters translate into real display geometry.
///
/// Two questions this answers, both of which block later phases:
///   • what combination actually yields a 2x (HiDPI) backing scale?
///   • do virtual displays ever publish a mode table to CGDisplayCopyDisplayMode?
///
/// Each row creates a real display, measures it, and tears it down.
func runProbe(_ args: Args) {
    print("=== Task 0.1 probe — mapping settings → geometry ===")
    print("host: \(hostInfo())\n")
    let before = DisplayInventory.activeDisplayIDs()

    struct Case {
        let label: String
        let modeW: UInt32
        let modeH: UInt32
        let hiDPI: Bool
        let maxOverride: (width: UInt32, height: UInt32)?
    }

    let cases: [Case] = [
        .init(label: "1080p mode, 1x, max=1x", modeW: 1920, modeH: 1080, hiDPI: false, maxOverride: nil),
        .init(label: "1080p mode, hiDPI, max=2x", modeW: 1920, modeH: 1080, hiDPI: true, maxOverride: nil),
        .init(label: "1080p mode, hiDPI, max=1x", modeW: 1920, modeH: 1080, hiDPI: true, maxOverride: (1920, 1080)),
        .init(label: "2160p mode, hiDPI, max=2160p", modeW: 3840, modeH: 2160, hiDPI: true, maxOverride: (3840, 2160)),
        .init(label: "2160p mode, 1x, max=2160p", modeW: 3840, modeH: 2160, hiDPI: false, maxOverride: (3840, 2160)),
    ]

    print(
        String(
            format: "%-30s %-14s %-14s %-8s %-8s", ("case" as NSString).utf8String!,
            ("points" as NSString).utf8String!, ("pixels" as NSString).utf8String!,
            ("scale" as NSString).utf8String!, ("modes?" as NSString).utf8String!))
    print(String(repeating: "-", count: 80))

    // CoreGraphics snapshots the display configuration per process on first
    // query and (in a CLI) never refreshes it, so only the FIRST case in a
    // process is trustworthy. --case runs exactly one, for use from a shell loop.
    let only = args.int("case", -1)
    for (index, c) in cases.enumerated() where only < 0 || only == index {
        var config = VirtualDisplayHost.Configuration()
        config.name = "DS Probe"
        config.width = c.modeW
        config.height = c.modeH
        config.hiDPI = c.hiDPI
        config.maxPixelsOverride = c.maxOverride
        config.refreshRate = 60

        let host = VirtualDisplayHost(config: config)
        do {
            let id = try host.start()
            // Give the window server a beat to settle the final geometry.
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            FileHandle.standardError.write(
                "   [dbg] id=0x\(String(id, radix: 16)) newlyAdded=\(!Set(before).contains(id))\n".data(using: .utf8)!)

            let bounds = CGDisplayBounds(id)
            let px = CGDisplayPixelsWide(id)
            let py = CGDisplayPixelsHigh(id)
            let scale = Double(px) / Double(max(bounds.width, 1))
            let modeCount =
                (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode])?.count ?? 0
            let hasCurrent = CGDisplayCopyDisplayMode(id) != nil

            print(
                String(
                    format: "%-30@ %-14@ %-14@ %-8@ %-8@",
                    c.label as NSString,
                    "\(Int(bounds.width))x\(Int(bounds.height))" as NSString,
                    "\(px)x\(py)" as NSString,
                    String(format: "%.2fx", scale) as NSString,
                    "\(modeCount) cur=\(hasCurrent ? "y" : "n")" as NSString))
        } catch {
            print(String(format: "%-30@ FAILED: \(error)", c.label as NSString))
        }
        host.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    print("\nDone. All probe displays torn down.")
    let leftovers = DisplayInventory.activeDisplayIDs().filter { CGDisplayVendorNumber($0) == 0x444D }
    print(leftovers.isEmpty ? "✅ no orphaned probe displays" : "❌ orphaned: \(leftovers)")
}
