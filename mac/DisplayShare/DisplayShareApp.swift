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
        // The product's own mark, as a template image: macOS tints template
        // images for light and dark menu bars itself, which is why it must be
        // monochrome. Falls back to an SF Symbol if the asset is ever missing,
        // rather than showing an empty menu bar item.
        MenuBarExtra {
            ControlPanel(
                controller: appDelegate.controller,
                openViewer: appDelegate.showViewerWindow
            )
        } label: {
            if let mark = NSImage(named: "MenuBarIcon") {
                Image(nsImage: mark)
            } else {
                Image(systemName: appDelegate.controller.state.isActive ? "display.2" : "display")
            }
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

        // Downloads, verifies and re-signs the latest release WITHOUT swapping
        // it in, then reports whether the designated requirement survived. Kept
        // as a permanent diagnostic: if it ever stops matching, every update
        // from that point on would silently cost the user their permissions.
        if CommandLine.arguments.contains("--check-update") {
            Task {
                // --apply-to <dir> runs the REAL swap against a copy. The dry
                // run proves everything up to the swap and nothing after it, so
                // without this the one step that replaces the user's app is the
                // only step never executed outside of production.
                var installed = URL(fileURLWithPath: "/Applications/DisplayShare.app")
                if let index = CommandLine.arguments.firstIndex(of: "--apply-to"),
                    index + 1 < CommandLine.arguments.count
                {
                    let target = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                    try? FileManager.default.removeItem(at: target)
                    try? FileManager.default.copyItem(at: installed, to: target)
                    installed = target
                    let updater = AutoUpdater(currentVersion: "0.0.1", installedAppURL: installed)
                    let outcome = await updater.applyIfAvailable(isStreaming: false)
                    print("apply: \(outcome)")
                    let version =
                        (try? String(
                            contentsOf: target.appendingPathComponent("Contents/Info.plist"),
                            encoding: .isoLatin1)) ?? ""
                    print("copy is now version: \(version.contains("0.7.0") ? "0.7.0" : "?")")
                    if let requirement = try? AutoUpdater.designatedRequirement(target) {
                        print("copy requirement: \(requirement)")
                    }
                    exit(String(describing: outcome).contains("applied") ? 0 : 1)
                }
                let updater = AutoUpdater(currentVersion: "0.0.1", installedAppURL: installed)
                let outcome = await updater.dryRun()
                print("dry run: \(outcome)")
                if let requirement = try? AutoUpdater.designatedRequirement(installed) {
                    print("installed: \(requirement)")
                }
                exit(outcome == .upToDate ? 0 : (String(describing: outcome).contains("applied") ? 0 : 1))
            }
            return
        }

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

        applyUpdateIfAvailable()

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
            ("res 1920x1080", { self.controller.setResolution(width: 1920, height: 1080) }),
            ("fps 60", { self.controller.setFrameRate(60) }),
            ("res 2560x1440", { self.controller.setResolution(width: 2560, height: 1440) }),
        ]
        // The property this hook exists to check is that reconfiguration keeps
        // the SAME display, so the user's window arrangement survives. Reported
        // as that property rather than as a hex id to diff by eye — which also
        // keeps a CGDirectDisplayID out of every string in this app.
        var firstDisplayID: CGDirectDisplayID?
        var delay: Double = 4
        for (label, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                action()
                let state: String
                switch self.controller.state {
                case .active(let id):
                    if firstDisplayID == nil { firstDisplayID = id }
                    state = id == firstDisplayID ? "active (same display)" : "active (NEW display)"
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

    /// Applies a pending update at launch (Task 9.1).
    ///
    /// Automatic application was chosen deliberately after the risk was raised.
    /// It is defensible because the payload is verified — the artifact's SHA-256
    /// must match the checksum published in the same release, fetched over TLS —
    /// and because AutoUpdater re-signs with the local identity and ABANDONS the
    /// update if the designated requirement would change. An update that cost
    /// the user their Screen Recording grant would be worse than no update.
    private func applyUpdateIfAvailable() {
        let bundle = Bundle.main.bundleURL
        let plan = UpdateScheduling.plan(
            bundlePath: bundle.path, arguments: CommandLine.arguments)

        if plan.notifyOnly {
            Task { await controller.checkForUpdate() }
            return
        }

        if plan.checkNow {
            runUpdateCheck(bundle: bundle)
        } else {
            log("update: running the freshly installed version")
        }

        // Scheduled even for a copy the updater just relaunched. Skipping this
        // along with the immediate check is what left an updated app never
        // looking again for the rest of its life — see UpdateScheduling.
        guard plan.scheduleRepeatingCheck else { return }
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: UpdateScheduling.interval, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.runUpdateCheck(bundle: bundle) }
        }
    }

    private var updateTimer: Timer?

    private func runUpdateCheck(bundle: URL) {
        Task { [weak self] in
            guard let self else { return }
            let updater = AutoUpdater(installedAppURL: bundle)
            // Streaming is honoured here too: a session in progress defers the
            // update to the next check rather than being torn down mid-use.
            let outcome = await updater.applyIfAvailable(isStreaming: controller.state.isActive)
            switch outcome {
            case .applied(let version, let permissionsReset):
                self.log("update: installed \(version), relaunching")
                if permissionsReset {
                    // The old copy was ad-hoc signed, so macOS sees a different
                    // app and drops its grants. Say so plainly; silently losing
                    // Screen Recording after an update is indistinguishable from
                    // the app breaking.
                    self.log(
                        "update: this copy was ad-hoc signed, so Screen Recording and "
                            + "Accessibility must be granted once more"
                    )
                }
                self.relaunch(bundle)
            case .upToDate:
                self.log("update: already current")
            case .skipped(let reason):
                self.log("update: skipped — \(reason)")
                // Still tell the user a version exists, so a skipped automatic
                // update does not silently become no update at all.
                await self.controller.checkForUpdate()
            case .failed(let reason):
                self.log("update: failed — \(reason)")
                await self.controller.checkForUpdate()
            }
        }
    }

    private func relaunch(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", bundle.path, "--args", "--updated"]
        try? process.run()
        NSApp.terminate(nil)
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
            let hosting = NSHostingController(rootView: ViewerView(controller: controller))
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

    private static let resolutions: [(label: String, width: UInt32, height: UInt32)] = [
        ("1280 × 720", 1280, 720),
        ("1920 × 1080", 1920, 1080),
        ("2560 × 1440", 2560, 1440),
    ]

    /// The order, as data (Command 9).
    ///
    /// Dividers used to be emitted by whichever block was visible, so an update
    /// notice followed by the browser fallback produced two in a row and a
    /// missing one elsewhere. Sections are now listed, then drawn with exactly
    /// one divider between neighbours — the rhythm cannot depend on which `if`
    /// happened to succeed.
    private var sections: [PopoverSection] {
        PopoverSection.ordered(
            isPairing: controller.pairingPIN != nil,
            needsScreenRecording: controller.needsScreenRecordingPermission,
            needsAccessibility: controller.needsAccessibilityPermission,
            hasUpdate: controller.availableUpdate != nil,
            hasBrowserFallback: controller.streamURL != nil,
            // Only when there is something to release, or something to bring
            // back. Otherwise it is a standing apology for a problem most
            // sessions never meet.
            canReleaseDisplay: controller.state.isActive || controller.displayReleased
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                if index > 0 { DSDivider() }
                view(for: section)
            }
        }
        .padding(DSPopoverMetrics.padding)
        .frame(width: DSPopoverMetrics.width)
        .onAppear {
            // Re-check on open: the user may have granted it in System Settings
            // while this panel was closed.
            controller.refreshAccessibilityState()
        }
    }

    @ViewBuilder
    private func view(for section: PopoverSection) -> some View {
        switch section {
        case .header: header
        case .status: statusSection
        case .pairing: pairingSection
        case .screenRecordingNotice: permissionNotice
        case .accessibilityNotice: accessibilityNotice
        case .display: displaySection
        case .update: updateSection
        case .browserFallback: browserFallbackSection
        case .otherDirection: otherDirectionSection
        case .protectedContent: protectedContentSection
        case .actions: actions
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.s2) {
            DSAppMark(size: 17).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text("Display Share").font(.headline)
                // The positioning line, which was previously buried as body copy
                // on the receiver and used nowhere else.
                Text("The second monitor you already own.")
                    .font(.system(size: DSFont.f2))
                    .foregroundStyle(DSColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Command 6, now leading the popover instead of sitting under a slider.
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.s2) {
            StatusPill(
                status: sessionStatus,
                fps: controller.socketStatistics.sentFPS,
                megabitsPerSecond: controller.socketStatistics.megabitsPerSecond,
                latencyMillis: controller.socketStatistics.roundTripMillis,
                sampleAge: 0
            )
            if controller.reattached {
                Text("Re-attached to an existing display — your windows were preserved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A pending PIN is the most important thing on screen when it exists.
    @ViewBuilder
    private var pairingSection: some View {
        if let pin = controller.pairingPIN {
            VStack(alignment: .leading, spacing: DSSpacing.s1) {
                Text("Pairing PIN").font(.caption).foregroundStyle(.secondary)
                Text(pin)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text("Type this on your PC to pair it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: DSSpacing.s2) {
            Text("Screen Recording permission is required to capture the display.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            DSButton("Open Privacy Settings…", variant: .secondary) {
                controller.openScreenRecordingSettings()
            }
        }
    }

    /// Only shown once a receiver has actually tried to send input, so it is not
    /// noise for people who only want a second screen.
    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: DSSpacing.s2) {
            Text("Remote control needs Accessibility permission.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            DSButton("Grant Accessibility…", variant: .secondary) {
                controller.requestAccessibilityPermission()
            }
        }
    }

    /// Resolution and frame rate — the only two settings that do anything.
    ///
    /// A "JPEG quality" slider used to sit here and outweigh the status line.
    /// It was DELETED rather than collapsed into an Advanced group: the JPEG
    /// encoder runs only under `codec == .mjpeg`, which is reachable only via a
    /// developer command-line flag, so in every shipped configuration the
    /// slider adjusted a number nothing read. The browser fallback is not the
    /// exception it looks like — that page is the WebCodecs H.264 client, not
    /// the MJPEG one.
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.s3) {
            // Resolution is applied to the LIVE display, so windows stay put.
            Picker("Resolution", selection: resolutionBinding) {
                ForEach(Self.resolutions, id: \.label) { option in
                    Text(option.label).tag("\(option.width)x\(option.height)")
                }
            }
            .tint(DSColor.accent)

            Picker("Frame rate", selection: frameRateBinding) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.segmented)
            // System blue was the most saturated thing in the popover and the
            // only colour in it that was not the brand's — the audit's first
            // cross-cutting issue was that no brand colour existed anywhere.
            .tint(DSColor.accent)

            Text("Resolution matches your PC's screen automatically once it connects.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        if let update = controller.availableUpdate {
            DSButton("Update available — \(update.version)", variant: .secondary) {
                controller.openUpdatePage()
            }
        }
    }

    /// The browser fallback, collapsed (Command 8).
    ///
    /// This URL was once the popover's most prominent instruction while
    /// pointing at a different port from the one the receiver dials, so a user
    /// reading the Mac and holding the app was told two different things.
    @ViewBuilder
    private var browserFallbackSection: some View {
        if let url = controller.streamURL {
            DisclosureGroup("Connect without the app") {
                VStack(alignment: .leading, spacing: DSSpacing.s2) {
                    Text("Open this address in a browser on the other machine. The app is the better path — this exists for machines you cannot install on.")
                        .font(.system(size: DSFont.f2))
                        .foregroundStyle(DSColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(url).font(.system(size: DSFont.f2, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        DSButton("Copy", variant: .secondary) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }
                    }
                }
                .padding(.top, DSSpacing.s1)
            }
            .font(.system(size: DSFont.f2))
            .foregroundStyle(DSColor.textMuted)
        }
    }

    /// The reverse direction, collapsed like the fallback rather than left as a
    /// bare button: "View a Windows PC" sitting next to Start/Stop gave no clue
    /// that the two do opposite things.
    private var otherDirectionSection: some View {
        DisclosureGroup("View a Windows PC") {
            VStack(alignment: .leading, spacing: DSSpacing.s2) {
                Text("Use this Mac to see and control a Windows PC — the opposite of what Start does.")
                    .font(.system(size: DSFont.f2))
                    .foregroundStyle(DSColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                DSButton("Open the viewer…", variant: .secondary) { openViewer() }
            }
            .padding(.top, DSSpacing.s1)
        }
        .font(.system(size: DSFont.f2))
        .foregroundStyle(DSColor.textMuted)
    }

    /// Phase 5. The one thing this app cannot fix, said plainly.
    ///
    /// Protected video is refused whenever any attached output cannot carry the
    /// copy protection it asks for, and it is refused on every display rather
    /// than only the offending one — so a virtual display stops Netflix on the
    /// Mac's own built-in screen. Filtering what we capture cannot help: the
    /// trigger is the display existing.
    ///
    /// Which leaves a choice, not a fix. What this section does is make it a
    /// choice the user makes deliberately, instead of one they discover through
    /// a playback error that explains nothing and names nothing.
    private var protectedContentSection: some View {
        Group {
            if controller.displayReleased {
                VStack(alignment: .leading, spacing: DSSpacing.s2) {
                    Text("Display released")
                        .font(.system(size: DSFont.f2, weight: .semibold))
                    Text(
                        "Protected video will play again. Your PC is still paired, "
                            + "so bringing the display back takes one click."
                    )
                    .font(.system(size: DSFont.f2))
                    .foregroundStyle(DSColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    DSButton("Bring the display back", variant: .secondary) {
                        controller.start()
                    }
                }
            } else {
                DisclosureGroup("Netflix or Prime Video not playing?") {
                    VStack(alignment: .leading, spacing: DSSpacing.s2) {
                        Text(
                            "Those services check every display attached to your Mac, not "
                                + "just the one they are playing on. This second screen "
                                + "cannot carry the copy protection they require, so they "
                                + "refuse to play anywhere while it exists — including on "
                                + "this Mac's own screen. Apple's Sidecar behaves the same "
                                + "way, for the same reason."
                        )
                        .font(.system(size: DSFont.f2))
                        .foregroundStyle(DSColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "Releasing the screen fixes it straight away. Your windows move "
                                + "back to this Mac, and your PC stays paired."
                        )
                        .font(.system(size: DSFont.f2))
                        .foregroundStyle(DSColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        DSButton("Release the screen", variant: .secondary) {
                            controller.releaseDisplay()
                        }
                    }
                    .padding(.top, DSSpacing.s1)
                }
                .font(.system(size: DSFont.f2))
                .foregroundStyle(DSColor.textMuted)
            }
        }
    }

    /// Command 7. Stop is an outline in error red, not a filled accent button —
    /// the control that ends the session was the loudest thing in the popover.
    /// It asks for the default action and is REFUSED it while active: the same
    /// button carried `.keyboardShortcut(.defaultAction)` through the title
    /// change, so Return with the popover open ended a running session.
    private var actions: some View {
        HStack {
            DSButton(
                controller.state.isActive ? "Stop" : "Start",
                variant: .forSession(isActive: controller.state.isActive),
                defaultAction: true
            ) {
                controller.state.isActive ? controller.stop() : controller.start()
            }

            Spacer()

            DSButton("Quit", variant: .ghost, shortcut: "q") {
                controller.shutdownForQuit()
                NSApp.terminate(nil)
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

    /// Derived rather than asserted: streaming requires a receiver attached AND
    /// frames actually flowing, which is the distinction the old green dot lost.
    private var sessionStatus: SessionStatus {
        let socket = controller.socketStatistics
        var failure: String?
        if case .failed(let message) = controller.state { failure = message }
        var starting = false
        if case .starting = controller.state { starting = true }
        return SessionStatus.derive(
            isActive: controller.state.isActive,
            isStarting: starting,
            failure: failure,
            connected: socket.connected,
            megabitsPerSecond: socket.megabitsPerSecond,
            client: controller.pairedClientName,
            droppedFrames: socket.receiverDroppedFrames
        )
    }

}
