import AppKit
import CoreGraphics
import Foundation

/// Test-only: puts continuously changing content on a display.
///
/// An idle virtual desktop emits SCFrameStatus.idle rather than new pixels, so
/// measuring throughput against one measures nothing (docs/phase0-findings.md).
final class AnimatedContent {
    private var window: NSWindow?
    private var timer: Timer?
    private var tick = 0

    /// Cocoa is bottom-left origin relative to the main display; CGDisplayBounds
    /// is top-left. Convert when NSScreen has not yet learned about the display.
    private static func cocoaFrame(for displayID: CGDirectDisplayID) -> NSRect {
        let cg = CGDisplayBounds(displayID)
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(x: cg.origin.x, y: mainHeight - (cg.origin.y + cg.height),
                      width: cg.width, height: cg.height)
    }

    func start(on displayID: CGDirectDisplayID) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        let frame = screen?.frame ?? Self.cocoaFrame(for: displayID)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.setFrame(frame, display: true)
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        w.contentView = view
        w.orderFrontRegardless()
        window = w

        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let layer = self.window?.contentView?.layer else { return }
            self.tick += 1
            let hue = CGFloat(self.tick % 60) / 60.0
            layer.backgroundColor = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil); window = nil
    }
}
