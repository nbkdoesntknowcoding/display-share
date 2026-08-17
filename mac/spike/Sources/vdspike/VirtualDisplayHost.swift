import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation

/// Thin wrapper over the private class cluster.
///
/// LIFECYCLE: the display lives exactly as long as `display` is retained by a
/// running process. Dropping the reference, exiting, or crashing removes the
/// display and macOS reflows every window that was on it. Task 1.1 moves this
/// into a dedicated `vd_helper` subprocess for exactly that reason.
final class VirtualDisplayHost {

    struct Configuration {
        var name: String = "Display Share"
        /// Logical (point) size of the desktop. With hiDPI the pixel framebuffer
        /// is twice this in each axis.
        var width: UInt32 = 1920
        var height: UInt32 = 1080
        var refreshRate: Double = 60
        var hiDPI: Bool = true
        /// Panel diagonal used to derive sizeInMillimeters. macOS infers DPI
        /// from physical size, which is what decides whether a HiDPI mode is
        /// offered at all — a wrong value here silently costs you Retina modes.
        var diagonalInches: Double = 15.6
        var vendorID: UInt32 = 0x444D  // "DM"
        var productID: UInt32 = 0x5348  // "SH"
        var serialNum: UInt32 = 0x0001

        /// Explicit override of the declared pixel ceiling. When nil it is
        /// derived as mode size x (hiDPI ? 2 : 1).
        var maxPixelsOverride: (width: UInt32, height: UInt32)?
    }

    let config: Configuration
    private var display: CGVirtualDisplay?
    private let queue = DispatchQueue(label: "in.theboringpeople.displayshare.vd")

    private(set) var displayID: CGDirectDisplayID = 0

    init(config: Configuration) {
        self.config = config
    }

    /// Physical size implied by the requested resolution and panel diagonal.
    private var sizeInMillimeters: CGSize {
        let w = Double(config.width)
        let h = Double(config.height)
        let diagonalPixels = (w * w + h * h).squareRoot()
        let mmPerPixel = (config.diagonalInches * 25.4) / diagonalPixels
        return CGSize(width: (w * mmPerPixel).rounded(), height: (h * mmPerPixel).rounded())
    }

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
                return "The display was created but never showed up in CGGetActiveDisplayList."
            }
        }
    }

    @discardableResult
    func start(onTerminate: (() -> Void)? = nil) throws -> CGDirectDisplayID {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = queue
        descriptor.name = config.name
        // maxPixels bounds the *pixel* framebuffer, while modes are expressed in
        // points. A HiDPI mode needs 2x headroom in each axis or CoreGraphics
        // silently drops back to a 1x backing scale.
        let scale: UInt32 = config.hiDPI ? 2 : 1
        descriptor.maxPixelsWide = config.maxPixelsOverride?.width ?? config.width * scale
        descriptor.maxPixelsHigh = config.maxPixelsOverride?.height ?? config.height * scale
        descriptor.sizeInMillimeters = sizeInMillimeters
        descriptor.vendorID = config.vendorID
        descriptor.productID = config.productID
        descriptor.serialNum = config.serialNum

        // sRGB primaries. Virtual displays are SDR-only; this just stops macOS
        // from inventing a colour profile.
        descriptor.redPrimary = CGPoint(x: 0.640, y: 0.330)
        descriptor.greenPrimary = CGPoint(x: 0.300, y: 0.600)
        descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)

        descriptor.terminationHandler = { _, _ in
            onTerminate?()
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw HostError.creationFailed
        }
        self.display = display

        guard applyMode(width: config.width, height: config.height, refreshRate: config.refreshRate) else {
            throw HostError.settingsRejected
        }

        // The display registers asynchronously; poll briefly rather than sleeping blind.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if DisplayInventory.activeDisplayIDs().contains(display.displayID) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        displayID = display.displayID
        guard displayID != 0, DisplayInventory.activeDisplayIDs().contains(displayID) else {
            throw HostError.displayNeverAppeared
        }
        return displayID
    }

    /// Re-applies a mode on the *existing* display. This is the path used for
    /// live resolution changes (Task 1.4) — it avoids destroying and recreating
    /// the display, which would scatter the user's windows.
    @discardableResult
    func applyMode(width: UInt32, height: UInt32, refreshRate: Double) -> Bool {
        guard let display else { return false }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        settings.rotation = 0

        // Modes are in POINTS. The first entry is the one macOS adopts.
        settings.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: refreshRate)]
        return display.apply(settings)
    }

    func stop() {
        display = nil
        displayID = 0
    }
}
