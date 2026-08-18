import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Watches the two permissions Display Share needs and reports the moment they
/// change, so onboarding can advance itself instead of telling the user to
/// relaunch.
///
/// The two behave differently, which is the whole reason this exists:
///
/// * **Accessibility** (`AXIsProcessTrusted`) flips live. Grant it and the very
///   next call returns true — no relaunch, ever.
/// * **Screen Recording** is more awkward. `CGPreflightScreenCaptureAccess()`
///   does update live, but a process that has already been REFUSED capture can
///   keep failing inside ScreenCaptureKit until it restarts. So the preflight
///   flag is not trusted on its own — a real `SCShareableContent` probe decides
///   whether capture will actually work, and only if the flag says yes while the
///   probe still fails does onboarding ask for a relaunch.
@MainActor
public final class PermissionMonitor: ObservableObject {

    public enum State: Equatable, Sendable {
        case unknown
        case denied
        /// Granted according to the flag, but capture still fails — relaunch needed.
        case grantedNeedsRestart
        case granted
    }

    @Published public private(set) var screenRecording: State = .unknown
    @Published public private(set) var accessibility: State = .unknown

    private var timer: Timer?
    private var probing = false
    private var checkingOutOfProcess = false
    private var outOfProcessChecksSinceLastRun = 0

    public init() {}

    public var screenRecordingGranted: Bool { screenRecording == .granted }

    /// SYNCHRONOUS read of the permission flag.
    ///
    /// `screenRecording` is refined by an async capture probe, so it is
    /// `.unknown` for the first moment after `refresh()`. Launch-time decisions
    /// must use this instead, or an app that already has permission looks
    /// unpermitted and re-onboards every launch.
    public static var screenRecordingFlag: Bool { CGPreflightScreenCaptureAccess() }
    public var accessibilityGranted: Bool { accessibility == .granted }

    /// Polls while an onboarding window is visible. Cheap: a flag read plus, at
    /// most, one shareable-content probe per transition.
    public func startMonitoring(interval: TimeInterval = 1.0) {
        stopMonitoring()
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        accessibility = AXIsProcessTrusted() ? .granted : .denied

        let flag = CGPreflightScreenCaptureAccess()
        if !flag {
            // CGPreflightScreenCaptureAccess CACHES its answer for the lifetime
            // of the process. An app that was running when the user granted
            // permission keeps reading false forever, so polling it can never
            // notice the grant — the window sits on "Not granted" while the
            // permission is plainly enabled in System Settings.
            //
            // A short-lived child process has no cached answer, so ask one.
            // Throttled: this costs a process spawn, and only runs while
            // onboarding is open and the flag still reads false.
            outOfProcessChecksSinceLastRun += 1
            if outOfProcessChecksSinceLastRun >= 3, !checkingOutOfProcess {
                outOfProcessChecksSinceLastRun = 0
                checkingOutOfProcess = true
                Self.grantedAccordingToFreshProcess { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        self.checkingOutOfProcess = false
                        // Granted in reality, invisible to THIS process: the
                        // only cure is a relaunch, so say exactly that.
                        self.screenRecording = granted ? .grantedNeedsRestart : .denied
                    }
                }
            } else if screenRecording != .grantedNeedsRestart {
                screenRecording = .denied
            }
            return
        }
        // The flag says yes. Confirm capture actually works before claiming it.
        if screenRecording != .granted, !probing {
            probing = true
            Self.probeCaptureAvailability { [weak self] usable in
                Task { @MainActor in
                    guard let self else { return }
                    self.probing = false
                    self.screenRecording = usable ? .granted : .grantedNeedsRestart
                }
            }
        }
    }

    /// Runs our own executable with `--check-permissions` and reads the answer.
    ///
    /// The point is the FRESH PROCESS: it has no cached preflight result, so it
    /// reports the permission as it stands right now rather than as it stood
    /// when this process launched.
    private static func grantedAccordingToFreshProcess(
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard let executable = Bundle.main.executableURL else { return completion(false) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--check-permissions"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        process.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            let granted = text.contains("CGPreflightScreenCaptureAccess: true")
            completion(granted)
        }
        do { try process.run() } catch { completion(false) }
    }

    /// Asks ScreenCaptureKit for content. Succeeding here is the only reliable
    /// evidence that capture will work in this process.
    private static func probeCaptureAvailability(completion: @escaping (Bool) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
            content, _ in
            completion((content?.displays.isEmpty == false))
        }
    }

    // MARK: - Requests

    public func requestScreenRecording() {
        // Raises the system prompt the first time. Afterwards it is a no-op and
        // the user must use Settings, so open that too.
        if !CGRequestScreenCaptureAccess() {
            openScreenRecordingSettings()
        }
    }

    public func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    public func requestAccessibility() {
        InputInjector.requestAccessibilityPermission()
        InputInjector.openAccessibilitySettings()
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Relaunches the app, for the one case where macOS will not let this
    /// process start capturing despite the permission being granted.
    public func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

/// Remembers whether onboarding has been completed.
public enum OnboardingRecord {
    private static let key = "in.theboringpeople.displayshare.onboardingCompletedVersion"
    /// Bumped when onboarding gains a step that existing users must also see.
    public static let currentVersion = 1

    public static var isComplete: Bool {
        UserDefaults.standard.integer(forKey: key) >= currentVersion
    }

    public static func markComplete() {
        UserDefaults.standard.set(currentVersion, forKey: key)
    }

    public static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
