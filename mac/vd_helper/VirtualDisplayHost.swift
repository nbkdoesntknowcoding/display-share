import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation

/// Owns the live `CGVirtualDisplay`.
///
/// LIFECYCLE: the display exists exactly as long as this object is retained by
/// a running process. Dropping the reference — or this process exiting or
/// crashing — destroys the display and macOS reflows every window that was on
/// it. That is the entire reason this lives in `vd_helper` rather than in the
/// app: a crash in the capture/encode pipeline must not cost the user their
/// window arrangement.
final class VirtualDisplayHost {

    enum HostError: Error, CustomStringConvertible {
        case creationFailed
        case settingsRejected
        case displayNeverAppeared

        var description: String {
            switch self {
            case .creationFailed:
                return "CGVirtualDisplay(descriptor:) returned nil — the private API refused to create a display."
            case .settingsRejected:
                return "applySettings: returned false — CoreGraphics rejected the mode list."
            case .displayNeverAppeared:
                return "Display was created but never appeared in CGGetActiveDisplayList."
            }
        }
    }

    private(set) var configuration: DisplayConfiguration?
    private(set) var displayID: CGDirectDisplayID = 0
    private var display: CGVirtualDisplay?
    private let queue = DispatchQueue(label: "in.theboringpeople.displayshare.vd")

    var isActive: Bool { display != nil && displayID != 0 }

    private func sizeInMillimeters(for config: DisplayConfiguration) -> CGSize {
        let w = Double(config.width)
        let h = Double(config.height)
        let diagonalPixels = (w * w + h * h).squareRoot()
        let mmPerPixel = (config.diagonalInches * 25.4) / diagonalPixels
        return CGSize(width: (w * mmPerPixel).rounded(), height: (h * mmPerPixel).rounded())
    }

    @discardableResult
    func start(_ config: DisplayConfiguration, onTerminate: @escaping () -> Void) throws -> CGDirectDisplayID {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = queue
        descriptor.name = config.name

        // maxPixels bounds the PIXEL framebuffer while modes are in points, so a
        // HiDPI mode needs 2x headroom in each axis.
        let scale: UInt32 = config.hiDPI ? 2 : 1
        descriptor.maxPixelsWide = config.width * scale
        descriptor.maxPixelsHigh = config.height * scale
        descriptor.sizeInMillimeters = sizeInMillimeters(for: config)

        descriptor.vendorID = 0x444D  // "DM"
        descriptor.productID = 0x5348  // "SH"
        descriptor.serialNum = 0x0001

        // sRGB primaries. Virtual displays are SDR-only; this simply stops macOS
        // from inventing a colour profile.
        descriptor.redPrimary = CGPoint(x: 0.640, y: 0.330)
        descriptor.greenPrimary = CGPoint(x: 0.300, y: 0.600)
        descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)

        descriptor.terminationHandler = { _, _ in onTerminate() }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw HostError.creationFailed
        }
        self.display = display

        guard applyMode(config) else { throw HostError.settingsRejected }

        // The display registers asynchronously; poll rather than sleeping blind.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if activeDisplayIDs().contains(display.displayID) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        displayID = display.displayID
        guard displayID != 0, activeDisplayIDs().contains(displayID) else {
            self.display = nil
            throw HostError.displayNeverAppeared
        }
        configuration = config
        return displayID
    }

    /// Re-applies a mode to the LIVE display. This is the path for resolution
    /// changes (Task 1.4) — it avoids destroy/recreate, so windows stay put.
    @discardableResult
    func applyMode(_ config: DisplayConfiguration) -> Bool {
        guard let display else { return false }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        settings.rotation = 0
        // Modes are expressed in POINTS. The first entry is the one macOS adopts.
        settings.modes = [
            CGVirtualDisplayMode(
                width: config.width, height: config.height, refreshRate: config.refreshRate)
        ]
        if display.apply(settings) {
            configuration = config
            return true
        }
        return false
    }

    func stop() {
        display = nil
        displayID = 0
        configuration = nil
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
