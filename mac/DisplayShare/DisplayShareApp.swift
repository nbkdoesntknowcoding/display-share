// Display Share — use a Windows laptop as a second display for a Mac.
// Copyright (C) 2026 Nischay B K
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version. See the LICENSE file at the repository root.

import AppKit
import ApplicationServices
import CoreGraphics
import DisplayShareCore
import ScreenCaptureKit
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
            ControlPanel(
                controller: appDelegate.controller,
                openViewer: appDelegate.showViewerWindow
            )
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // --codec mjpeg selects the Phase 1 path, for the Task 2.4 comparison.
    let permissions = PermissionMonitor()
    /// Owned directly rather than as a SwiftUI Window scene: showing and hiding a
    /// scene from an AppDelegate depends on private selectors, and this window
    /// must appear reliably on a genuinely fresh install.
    private var onboardingWindow: NSWindow?

    let controller = DisplayShareController(
        codec: CommandLine.arguments.contains("mjpeg") ? .mjpeg : .h264,
        // --no-pairing is for automated tests only; pairing is on by default.
        requirePairing: !CommandLine.arguments.contains("--no-pairing"))

    /// `--check-permissions` prints what THIS bundle can actually see and exits.
    /// Permission bugs are otherwise impossible to diagnose from outside: a probe
    /// run from a terminal reports the terminal's TCC identity, not the app's.
    private func runPermissionDiagnosticIfRequested() {
        guard CommandLine.arguments.contains("--check-permissions") else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "?"
        var out = "bundle id                     : \(bundleID)\n"
        out += "bundle path                   : \(Bundle.main.bundleURL.path)\n"
        out += "CGPreflightScreenCaptureAccess: \(CGPreflightScreenCaptureAccess())\n"
        out += "AXIsProcessTrusted            : \(AXIsProcessTrusted())\n"

        // Deliberately NOT calling SCShareableContent unless asked: that call
        // RAISES THE SYSTEM PERMISSION PROMPT when unauthorised. This diagnostic
        // is run repeatedly and non-interactively, so prompting here produced a
        // storm of dialogs. The flags above prompt for nothing.
        if CommandLine.arguments.contains("--deep") {
            let semaphore = DispatchSemaphore(value: 0)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
                content, error in
                out += "SCShareableContent displays   : \(content?.displays.count ?? -1)\n"
                out += "SCShareableContent error      : \(error?.localizedDescription ?? "none")\n"
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 10)
        }

        FileHandle.standardError.write(Data(out.utf8))
        // --out writes the same report to a file. Necessary because stderr is
        // discarded when the app is launched through LaunchServices, and that
        // is the ONLY way to observe the app's real TCC identity: run the
        // binary from a shell and macOS attributes it to the terminal instead.
        if let index = CommandLine.arguments.firstIndex(of: "--out"),
            index + 1 < CommandLine.arguments.count
        {
            try? out.write(
                toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
        }
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runPermissionDiagnosticIfRequested()

        // Opens the viewer straight away. Kept as a permanent diagnostic: a
        // menu bar item cannot be clicked from a script without an
        // Accessibility grant, so without this there is no way to tell a
        // menu-wiring fault from a window-presentation one — which is exactly
        // the distinction that mattered when this button first did nothing.
        if CommandLine.arguments.contains("--viewer") {
            DispatchQueue.main.async { self.showViewerWindow() }
        }

        // Menu bar only — no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        // Check once at launch. Never downloads or installs on its own — this
        // app is unsigned, so a silent self-replacing binary would be exactly
        // the behaviour a user should distrust.
        Task { await controller.checkForUpdate() }

        permissions.refresh()
        // Show onboarding when it has never been completed, or when the required
        // permission is missing — a user who revoked it needs the explanation
        // again, not a silently broken app.
        // Use the SYNCHRONOUS flag: permissions.screenRecording is still
        // .unknown here because its capture probe is async.
        let hasScreenRecording = PermissionMonitor.screenRecordingFlag
        let needsOnboarding = !OnboardingRecord.isComplete || !hasScreenRecording
        log(
            "complete=\(OnboardingRecord.isComplete) screenRecordingFlag=\(hasScreenRecording) -> needsOnboarding=\(needsOnboarding)")
        if needsOnboarding && !CommandLine.arguments.contains("--skip-onboarding") {
            showOnboarding()
        }

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

        // Test-only: exercises the recovery path the wake notification triggers,
        // without suspending the machine running the test.
        if let index = CommandLine.arguments.firstIndex(of: "--test-recover-after"),
            index + 1 < CommandLine.arguments.count,
            let delay = Double(CommandLine.arguments[index + 1])
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.controller.supervisor.recover(reason: "test hook (wake path)")
            }
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

    func showOnboarding() {
        log("showing onboarding")
        // A window needs a regular activation policy to come forward; drop back
        // to accessory afterwards so no Dock icon lingers.
        NSApp.setActivationPolicy(.regular)

        if onboardingWindow == nil {
            let hosting = NSHostingController(
                rootView: OnboardingView(monitor: permissions) { [weak self] in
                    self?.finishOnboarding()
                })
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Display Share"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        // Present on the NEXT run-loop turn. An LSUIElement app switching to
        // .regular during applicationDidFinishLaunching is not yet foreground-
        // capable, so ordering front in the same turn silently does nothing.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.onboardingWindow else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            self?.log("window visible=\(window.isVisible) frame=\(window.frame)")
        }
    }

    private func dismissOnboardingWindow() {
        onboardingWindow?.close()
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data("[DisplayShare] onboarding: \(text)\n".utf8))
    }

    func finishOnboarding() {
        log("finished by user")
        OnboardingRecord.markComplete()
        dismissOnboardingWindow()
        NSApp.setActivationPolicy(.accessory)
        permissions.stopMonitoring()
        // Start immediately when possible, so "reaches a working second display"
        // needs no further clicks.
        if permissions.screenRecordingGranted, !controller.state.isActive {
            controller.start()
        }
    }

    /// Opening an already-running menu bar app must show SOMETHING.
    ///
    /// Display Share is LSUIElement: no Dock icon, no window. Double-clicking it
    /// in Finder therefore appeared to do nothing at all, which reads as "the
    /// app is broken" rather than "it is already running up in the menu bar".
    /// macOS calls this on every reopen, so use it to surface the status window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showStatusWindow() }
        return true
    }

    /// Shows onboarding when a permission is still missing, otherwise a short
    /// "it is running, here is where" panel.
    private func showStatusWindow() {
        if !PermissionMonitor.screenRecordingFlag || !OnboardingRecord.isComplete {
            showOnboarding()
            return
        }
        NSApp.setActivationPolicy(.regular)
        if runningWindow == nil {
            let hosting = NSHostingController(rootView: RunningView(controller: controller))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Display Share"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            runningWindow = window
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.runningWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private var runningWindow: NSWindow?

    /// The Mac viewing a Windows desktop (Task 8.2).
    ///
    /// A window rather than a whole second app: the app already installed on
    /// this machine gains a second role. Shipping a separate viewer was
    /// rejected because two near-identically named apps already caused real
    /// confusion in this project.
    private var viewerWindow: NSWindow?

    func showViewerWindow() {
        // Viewing needs no Screen Recording or Accessibility grant — nothing is
        // captured or injected here — so this deliberately does not run the
        // onboarding gate that showStatusWindow() does.
        NSApp.setActivationPolicy(.regular)
        if viewerWindow == nil {
            let hosting = NSHostingController(rootView: ViewerView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Windows PC"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 960, height: 600))
            window.center()
            viewerWindow = window
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.viewerWindow?.makeKeyAndOrderFront(nil)
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
    /// Opening the viewer is handed in rather than recovered from
    /// `NSApp.delegate`: SwiftUI's `NSApplicationDelegateAdaptor` installs its
    /// OWN forwarding delegate, so `NSApp.delegate as? AppDelegate` is nil and
    /// the optional-chained call silently did nothing.
    let openViewer: () -> Void
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

            // A pending PIN is the most important thing on screen when it exists.
            if let pin = controller.pairingPIN {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pairing PIN").font(.caption).foregroundStyle(.secondary)
                    Text(pin)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Type this on the receiver to pair it.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
            }

            if controller.needsScreenRecordingPermission {
                permissionNotice
                Divider()
            }

            // Only shown once a receiver has actually tried to send input, so
            // it is not noise for people who only want a second screen.
            if controller.needsAccessibilityPermission {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Remote control needs Accessibility permission.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Grant Accessibility…") { controller.requestAccessibilityPermission() }
                }
                Divider()
            }

            controls

            if let update = controller.availableUpdate {
                Button("Update available — \(update.version)") {
                    controller.openUpdatePage()
                }
                Divider()
            }

            if let url = controller.streamURL {
                Divider()
                receiverSection(url: url)
            }

            Divider()

            Divider()

            Button("View a Windows PC…") { openViewer() }

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
        .onAppear {
            quality = controller.jpegQuality
            // Re-check on open: the user may have granted it in System Settings
            // while this panel was closed.
            controller.refreshAccessibilityState()
        }
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
