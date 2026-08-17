import AppKit
import DisplayShareCore
import SwiftUI

/// Menu bar app. Phase 1 scope is the display lifecycle only — capture,
/// encode and the MJPEG server arrive in Tasks 1.2–1.4.
@main
struct DisplayShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Display Share", systemImage: appDelegate.controller.state.isActive ? "display.2" : "display") {
            MenuContent(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DisplayShareController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        // Lets the lifecycle acceptance tests (and later CI) drive the app
        // without a human clicking the menu bar.
        if CommandLine.arguments.contains("--autostart") {
            controller.start()
        }
    }

    /// A clean quit must remove the display immediately rather than leaving the
    /// helper to time out its grace period.
    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdownForQuit()
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: DisplayShareController

    var body: some View {
        Text(statusText)

        if controller.reattached {
            Text("Re-attached to an existing display")
        }

        Divider()

        if controller.state.isActive {
            Button("Stop Display") { controller.stop() }
        } else {
            Button("Start Display") { controller.start() }
        }

        Divider()

        Menu("Resolution") {
            resolutionButton("1280 × 720", width: 1280, height: 720)
            resolutionButton("1920 × 1080", width: 1920, height: 1080)
            resolutionButton("2560 × 1440", width: 2560, height: 1440)
        }

        Divider()

        Button("Quit Display Share") {
            controller.shutdownForQuit()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        switch controller.state {
        case .idle: return "Inactive"
        case .starting: return "Starting…"
        case .active(let id): return "Active — display 0x\(String(id, radix: 16))"
        case .failed(let message): return "Error: \(message)"
        }
    }

    private func resolutionButton(_ title: String, width: UInt32, height: UInt32) -> some View {
        Button {
            var config = controller.configuration
            config.width = width
            config.height = height
            controller.update(configuration: config)
        } label: {
            let selected = controller.configuration.width == width && controller.configuration.height == height
            Text(selected ? "✓ \(title)" : title)
        }
    }
}
