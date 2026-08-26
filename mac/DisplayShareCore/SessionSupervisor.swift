import AppKit
import CoreGraphics
import Foundation

/// Keeps a session alive across the things that actually break it in real use:
/// sleep/wake, Wi-Fi drops, display reconfiguration, and a capture stream that
/// dies quietly.
///
/// Design rule from the build plan: on recovery, **tear down and recreate the
/// virtual display only if its geometry changed**. Recreating it otherwise costs
/// the user their window arrangement, which is the one thing this architecture
/// exists to protect. Everything else is resumed by restarting capture and
/// forcing an IDR.
///
/// Phase 0 found that a process which registers a reconfiguration callback
/// without servicing it freezes CoreGraphics' view of the display set. The app
/// runs a real NSApplication run loop, so the callback is delivered here — but
/// `observedReconfigurations` records whether it actually fired, so the
/// assumption is checked rather than trusted.
public final class SessionSupervisor: @unchecked Sendable {

    public struct Event: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case willSleep
            case didWake
            case displayReconfigured
            case captureStalled
            case captureStopped
            case recovered
        }
        public var kind: Kind
        public var detail: String
        public var at: Date
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var lastFrameCount = 0
    private var lastProgressAt = Date()
    private var asleep = false
    private var recovering = false

    /// How long capture may show no sign of life before it is treated as
    /// stalled.
    ///
    /// This used to be measured against ENCODED frames, and a long timeout was
    /// the defence against a still desktop: ScreenCaptureKit encodes nothing
    /// while nothing changes, so six seconds of reading a document looked
    /// exactly like a dead stream. It did not work — it only postponed the
    /// mistake. Past the timeout, capture was torn down and restarted and a
    /// keyframe forced, every six seconds, for as long as nobody touched the
    /// machine. The user's reward for sitting still was a hitch and an IDR
    /// burst on repeat.
    ///
    /// It is now measured against `captureHeartbeat`, which advances for idle
    /// frames too. A still desktop proves the stream is alive without producing
    /// a single pixel, so the timeout can go back to meaning what it says.
    public var stallTimeout: TimeInterval = 6.0

    /// Asked to restart capture (and force a keyframe). Returns true on success.
    public var onRecoverCapture: (() -> Bool)?
    /// Asked for a counter that advances whenever capture is delivering —
    /// including frames that carry no new pixels.
    ///
    /// Named for what it must be given, because nothing can check. This used to
    /// be `frameCountProvider`, and an encoded-frame count satisfied it
    /// perfectly while being the wrong question: "has anything changed on
    /// screen" and "is the capture stream alive" are different, and only the
    /// second is a fault when the answer is no. Handing this a throughput
    /// counter is now visibly wrong at the call site, which is the only place
    /// the mistake can be caught.
    public var captureHeartbeatProvider: (() -> Int)?
    /// True while a receiver is attached; no receiver means no frames are
    /// expected and a stall is not a fault.
    public var hasReceiver: (() -> Bool)?

    public private(set) var observedReconfigurations = 0
    public private(set) var recoveries = 0

    public var recentEvents: [Event] {
        lock.lock(); defer { lock.unlock() }
        return events.suffix(50)
    }

    private func record(_ kind: Event.Kind, _ detail: String = "") {
        lock.lock()
        events.append(Event(kind: kind, detail: detail, at: Date()))
        if events.count > 500 { events.removeFirst(events.count - 500) }
        lock.unlock()
        FileHandle.standardError.write(
            Data("[DisplayShare] session: \(kind.rawValue) \(detail)\n".utf8))
    }

    // MARK: - Lifecycle

    public func start() {
        let center = NSWorkspace.shared.notificationCenter

        observers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.asleep = true; self.lock.unlock()
                self.record(.willSleep)
            })

        observers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.asleep = false; self.lock.unlock()
                self.record(.didWake)
                // ScreenCaptureKit routinely comes back dead after a wake, and
                // the window server may not have finished republishing displays,
                // so give it a beat before rebuilding.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.recover(reason: "wake")
                }
            })

        // Screen lock / unlock is a distinct signal from sleep and shows the same
        // symptom (capture goes quiet), so treat it the same way.
        observers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.record(.didWake, "screens")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.recover(reason: "screens woke")
                }
            })

        SupervisorReconfiguration.shared.onReconfigure = { [weak self] displayID, flags in
            guard let self else { return }
            self.observedReconfigurations += 1
            self.record(
                .displayReconfigured,
                "display 0x\(String(displayID, radix: 16)) flags 0x\(String(flags.rawValue, radix: 16))")
        }
        SupervisorReconfiguration.shared.register()

        // Watchdog: catches the failures that arrive with no notification at all,
        // such as a Wi-Fi drop that leaves the socket half-open.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkProgress()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        lastProgressAt = Date()
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        watchdog?.invalidate()
        watchdog = nil
        SupervisorReconfiguration.shared.unregister()
    }

    /// Call when a session starts, so the watchdog does not fire on startup.
    public func noteSessionStarted() {
        lock.lock()
        lastFrameCount = captureHeartbeatProvider?() ?? 0
        lastProgressAt = Date()
        lock.unlock()
    }

    // MARK: - Health

    /// Internal rather than private so the stall decision can be driven
    /// directly in tests. Waiting on a two-second timer to observe a
    /// six-second timeout is not a test anyone runs twice.
    func checkProgress() {
        lock.lock()
        let sleeping = asleep
        let busy = recovering
        lock.unlock()
        guard !sleeping, !busy else { return }

        // With no receiver attached nothing is being encoded, so silence is
        // expected and must not be mistaken for a stall.
        guard hasReceiver?() == true else {
            lock.lock(); lastProgressAt = Date(); lock.unlock()
            return
        }

        let current = captureHeartbeatProvider?() ?? 0
        lock.lock()
        if current != lastFrameCount {
            lastFrameCount = current
            lastProgressAt = Date()
            lock.unlock()
            return
        }
        let stalledFor = Date().timeIntervalSince(lastProgressAt)
        lock.unlock()

        if stalledFor > stallTimeout {
            record(.captureStalled, String(format: "no frames for %.1fs", stalledFor))
            recover(reason: "stall")
        }
    }

    /// Called when SCStream reports it stopped on its own.
    public func noteCaptureStopped(_ error: Error) {
        record(.captureStopped, "\(error)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.recover(reason: "stream stopped")
        }
    }

    public func recover(reason: String) {
        lock.lock()
        if recovering {
            lock.unlock()
            return
        }
        recovering = true
        lock.unlock()

        let started = Date()
        let ok = onRecoverCapture?() ?? false
        let elapsed = Date().timeIntervalSince(started)

        lock.lock()
        recovering = false
        lastFrameCount = captureHeartbeatProvider?() ?? 0
        lastProgressAt = Date()
        if ok { recoveries += 1 }
        lock.unlock()

        record(
            .recovered,
            String(format: "%@ after %@ in %.2fs", ok ? "ok" : "FAILED", reason, elapsed))
    }
}

/// CGDisplayRegisterReconfigurationCallback takes a C function pointer, which
/// cannot capture context — hence the singleton.
final class SupervisorReconfiguration {
    nonisolated(unsafe) static let shared = SupervisorReconfiguration()
    var onReconfigure: ((CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void)?
    private var registered = false

    func register() {
        guard !registered else { return }
        registered = true
        CGDisplayRegisterReconfigurationCallback(supervisorReconfigCallback, nil)
    }

    func unregister() {
        guard registered else { return }
        registered = false
        CGDisplayRemoveReconfigurationCallback(supervisorReconfigCallback, nil)
    }
}

private func supervisorReconfigCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    SupervisorReconfiguration.shared.onReconfigure?(displayID, flags)
}
