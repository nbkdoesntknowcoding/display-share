import AppKit
import CoreGraphics
import Foundation

/// Puts continuously-changing content on a specific display so capture can be
/// proven to track live updates.
///
/// An idle virtual desktop is static, and ScreenCaptureKit deliberately emits
/// `.idle` frames rather than re-sending unchanged pixels — so "every frame is
/// identical" on an empty desktop proves nothing either way. This gives the
/// capture path something that genuinely changes every tick.
final class AnimatedContent {
    private var window: NSWindow?
    private var timer: Timer?
    private var tick = 0

    /// Cocoa's global coordinate space is bottom-left origin relative to the
    /// main display; CGDisplayBounds is top-left origin. Convert when NSScreen
    /// has not yet learned about the display.
    private static func cocoaFrame(for displayID: CGDirectDisplayID) -> NSRect {
        let cg = CGDisplayBounds(displayID)
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(
            x: cg.origin.x,
            y: mainHeight - (cg.origin.y + cg.height),
            width: cg.width,
            height: cg.height)
    }

    func start(on displayID: CGDirectDisplayID) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        let frame = screen?.frame ?? Self.cocoaFrame(for: displayID)

        let window = NSWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.setFrame(frame, display: true)
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.backgroundColor = .black

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window

        // Repaint every ~16ms so there is a fresh surface for every 60fps frame.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let layer = self.window?.contentView?.layer else { return }
            self.tick += 1
            // Large, high-contrast changes: whole-surface colour cycling
            // guarantees a big per-frame pixel delta that is unambiguous.
            let hue = CGFloat(self.tick % 60) / 60.0
            layer.backgroundColor = NSColor(hue: hue, saturation: 1.0, brightness: 1.0, alpha: 1.0).cgColor
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var frame: NSRect? { window?.frame }

    func stop() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }
}
