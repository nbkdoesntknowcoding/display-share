import AppKit
import DisplayShareCore
import SwiftUI

/// Menu bar app.
///
/// Uses `.window` style rather than `.menu` because Task 1.4 requires a JPEG
/// quality slider, and NSMenu cannot host a live control.
@main
struct DisplayShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra(
            "Display Share",
            systemImage: appDelegate.controller.state.isActive ? "display.2" : "display"
        ) {
            ControlPanel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // --codec mjpeg selects the Phase 1 path, for the Task 2.4 comparison.
    let controller = DisplayShareController(
        codec: CommandLine.arguments.contains("mjpeg") ? .mjpeg : .h264)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        // Lets the lifecycle acceptance tests (and later CI) drive the app
        // without a human clicking the menu bar.
        if CommandLine.arguments.contains("--autostart") {
            controller.start()
        }

        // Test-only: drives the same controller methods the panel calls, so the
        // Task 1.4 acceptance can be checked without a human clicking. Inert
        // unless the flag is passed; deliberately NOT a network control surface.
        if CommandLine.arguments.contains("--test-cycle") {
            runLiveReconfigurationCycle()
        }
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("[cycle] \(message)\n".utf8))
    }

    private func runLiveReconfigurationCycle() {
        let steps: [(String, () -> Void)] = [
            ("res 1280x720", { self.controller.setResolution(width: 1280, height: 720) }),
            ("fps 30", { self.controller.setFrameRate(30) }),
            ("quality 0.3", { self.controller.jpegQuality = 0.3 }),
            ("res 1920x1080", { self.controller.setResolution(width: 1920, height: 1080) }),
            ("fps 60", { self.controller.setFrameRate(60) }),
            ("quality 0.9", { self.controller.jpegQuality = 0.9 }),
            ("res 2560x1440", { self.controller.setResolution(width: 2560, height: 1440) }),
        ]
        var delay: Double = 4
        for (label, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                action()
                let state: String
                switch self.controller.state {
                case .active(let id): state = "active 0x\(String(id, radix: 16))"
                case .failed(let m): state = "FAILED \(m)"
                case .idle: state = "idle"
                case .starting: state = "starting"
                }
                self.note("\(label) -> \(state)")
            }
            delay += 4
        }
    }

    /// A clean quit must remove the display immediately rather than leaving the
    /// helper to time out its grace period.
    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdownForQuit()
    }
}

private struct ControlPanel: View {
    @ObservedObject var controller: DisplayShareController
    @State private var quality: Double = 0.7

    private static let resolutions: [(label: String, width: UInt32, height: UInt32)] = [
        ("1280 × 720", 1280, 720),
        ("1920 × 1080", 1920, 1080),
        ("2560 × 1440", 2560, 1440),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if controller.needsScreenRecordingPermission {
                permissionNotice
                Divider()
            }

            controls

            if let url = controller.streamURL {
                Divider()
                receiverSection(url: url)
            }

            Divider()

            HStack {
                Button(controller.state.isActive ? "Stop" : "Start") {
                    controller.state.isActive ? controller.stop() : controller.start()
                }
                .keyboardShortcut(.defaultAction)

                Spacer()

                Button("Quit") {
                    controller.shutdownForQuit()
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { quality = controller.jpegQuality }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Display Share").font(.headline)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
            if controller.reattached {
                Text("Re-attached to an existing display — your windows were preserved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen Recording permission is required to capture the display.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings…") { controller.openScreenRecordingSettings() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Resolution is applied to the LIVE display, so windows stay put.
            Picker("Resolution", selection: resolutionBinding) {
                ForEach(Self.resolutions, id: \.label) { option in
                    Text(option.label).tag("\(option.width)x\(option.height)")
                }
            }

            Picker("Frame rate", selection: frameRateBinding) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("JPEG quality").font(.caption)
                    Spacer()
                    Text(String(format: "%.0f%%", quality * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // Encoder-only setting: no display or stream restart needed,
                // so it can move under the user's finger.
                Slider(value: $quality, in: 0.2...1.0, step: 0.05)
                    .onChange(of: quality) { _, newValue in
                        controller.jpegQuality = newValue
                    }
            }

            Text("Matching the receiver's panel automatically arrives with the Windows client (Task 3.3).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func receiverSection(url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open on the receiver").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(url).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
        }
    }

    // MARK: - Bindings

    private var resolutionBinding: Binding<String> {
        Binding(
            get: { "\(controller.configuration.width)x\(controller.configuration.height)" },
            set: { value in
                let parts = value.split(separator: "x").compactMap { UInt32($0) }
                guard parts.count == 2 else { return }
                controller.setResolution(width: parts[0], height: parts[1])
            })
    }

    private var frameRateBinding: Binding<Int> {
        Binding(
            get: { Int(controller.configuration.refreshRate) },
            set: { controller.setFrameRate($0) })
    }

    private var statusText: String {
        switch controller.state {
        case .idle: return "Inactive"
        case .starting: return "Starting…"
        case .active(let id):
            let stats = controller.statistics
            return String(
                format: "Display 0x%@ · %.0f fps · %.1f Mbps",
                String(id, radix: 16), stats.captureFPS, stats.megabitsPerSecond)
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .failed: return .red
        case .active: return .green
        default: return .secondary
        }
    }
}
