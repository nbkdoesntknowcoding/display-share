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
    private var bar: CALayer?

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

        // Text at several sizes, so "is text legibly sharp at 1080p?" can be
        // judged on the receiver rather than asserted.
        if ProcessInfo.processInfo.environment["DS_TEXT"] != nil {
            let sizes: [CGFloat] = [11, 13, 16, 24, 48]
            var y = frame.height - 140
            for size in sizes {
                let label = NSTextField(labelWithString:
                    "\(Int(size))pt — The quick brown fox jumps over the lazy dog. 0123456789 il1 O0 rn/m")
                label.font = .monospacedSystemFont(ofSize: size, weight: .regular)
                label.textColor = .black
                label.backgroundColor = .white
                label.drawsBackground = true
                label.frame = NSRect(x: 40, y: y, width: frame.width - 80, height: size * 1.8)
                view.addSubview(label)
                y -= size * 2.4 + 12
            }
            let heading = NSTextField(labelWithString: "Display Share — 1080p text legibility check")
            heading.font = .systemFont(ofSize: 34, weight: .semibold)
            heading.textColor = .black
            heading.backgroundColor = .white
            heading.drawsBackground = true
            heading.frame = NSRect(x: 40, y: frame.height - 90, width: frame.width - 80, height: 50)
            view.addSubview(heading)
        }
        w.orderFrontRegardless()
        window = w

        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let layer = self.window?.contentView?.layer else { return }
            self.tick += 1
            if ProcessInfo.processInfo.environment["DS_TEXT"] != nil {
                // Keep frames flowing without destroying text contrast: a thin
                // moving bar rather than a full-surface colour cycle.
                layer.backgroundColor = NSColor.white.cgColor
                if let bar = self.bar {
                    bar.frame.origin.x = CGFloat((self.tick * 6) % Int(layer.bounds.width))
                } else {
                    let bar = CALayer()
                    bar.frame = CGRect(x: 0, y: 0, width: 60, height: layer.bounds.height)
                    bar.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
                    layer.addSublayer(bar)
                    self.bar = bar
                }
                return
            }
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
