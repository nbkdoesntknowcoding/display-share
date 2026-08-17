import CoreGraphics
import Foundation

/// Snapshot helpers used to *prove* a virtual display really joined the system,
/// rather than trusting that the private API returned without error.
enum DisplayInventory {

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Human-readable description of one display, including the point-vs-pixel
    /// distinction that tells us whether HiDPI actually took effect.
    static func describe(_ id: CGDirectDisplayID) -> String {
        let bounds = CGDisplayBounds(id)
        var line = """
            display 0x\(String(id, radix: 16))
              bounds        : origin (\(Int(bounds.origin.x)), \(Int(bounds.origin.y))) size \(Int(bounds.size.width))x\(Int(bounds.size.height)) pt
              pixels        : \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))
              builtin       : \(CGDisplayIsBuiltin(id) != 0)
              main          : \(CGDisplayIsMain(id) != 0)
              online        : \(CGDisplayIsOnline(id) != 0)
              active        : \(CGDisplayIsActive(id) != 0)
              vendor/model  : 0x\(String(CGDisplayVendorNumber(id), radix: 16)) / 0x\(String(CGDisplayModelNumber(id), radix: 16))
              serial        : 0x\(String(CGDisplaySerialNumber(id), radix: 16))
            """

        if let mode = CGDisplayCopyDisplayMode(id) {
            let scale = Double(mode.pixelWidth) / Double(max(mode.width, 1))
            line += """

              current mode  : \(mode.width)x\(mode.height) pt / \(mode.pixelWidth)x\(mode.pixelHeight) px \
            @ \(String(format: "%.2f", mode.refreshRate)) Hz  (backing scale \(String(format: "%.1f", scale))x)
            """
        }
        return line
    }

    /// Every mode macOS is willing to offer for this display. Confirms the
    /// 60 Hz ceiling and shows which HiDPI variants exist.
    static func describeModes(_ id: CGDirectDisplayID) -> String {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode], !modes.isEmpty else {
            return "  (no modes reported)"
        }
        return modes.map { m in
            let scale = Double(m.pixelWidth) / Double(max(m.width, 1))
            return String(
                format: "    %5d x %-5d pt  |  %5d x %-5d px  |  %6.2f Hz  |  %.1fx",
                m.width, m.height, m.pixelWidth, m.pixelHeight, m.refreshRate, scale)
        }.joined(separator: "\n")
    }
}

/// `vdspike list` — prints active displays as `id vendor width height`.
/// Used by the helper lifecycle acceptance tests, which need a fresh process
/// per query because CoreGraphics snapshots display config per process.
func runList(_ args: Args) {
    for id in DisplayInventory.activeDisplayIDs() {
        let b = CGDisplayBounds(id)
        print("0x\(String(id, radix: 16)) 0x\(String(CGDisplayVendorNumber(id), radix: 16)) \(Int(b.width)) \(Int(b.height))")
    }
    exit(0)
}
