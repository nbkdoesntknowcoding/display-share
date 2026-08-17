import CoreGraphics
import Foundation

/// CoreGraphics caches the display/mode table **per process**. The cache is
/// refreshed when the process handles a display-reconfiguration notification,
/// which requires (a) a registered callback and (b) a running run loop.
///
/// Without this, a process that queried display modes *before* creating a
/// virtual display can keep serving the stale pre-creation answer:
/// CGDisplayCopyDisplayMode returns nil and CGDisplayCopyAllDisplayModes
/// returns an empty list for the new display, even though the display is
/// demonstrably online and has correct bounds.
///
/// This matters well beyond the spike — Task 3.3 (resolution negotiation) and
/// Task 4.2 (sleep/wake and reconfiguration handling) both depend on the sender
/// having a fresh view of display geometry.

// Spike-only global: the callback is a C function pointer and cannot capture
// context. The spike is single-threaded and CG delivers these on the main run
// loop, so unchecked global state is acceptable here.
nonisolated(unsafe) private var observedEvents:
    [(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags)] = []

private func reconfigCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    observedEvents.append((displayID, flags))
}

final class ReconfigurationWatcher {

    func start() {
        observedEvents.removeAll()
        CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)
    }

    func stop() {
        CGDisplayRemoveReconfigurationCallback(reconfigCallback, nil)
    }

    var events: [(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags)] { observedEvents }

    var summary: String {
        observedEvents.isEmpty
            ? "  (none — CoreGraphics never told this process the display layout changed)"
            : observedEvents.map {
                "  0x\(String($0.display, radix: 16))  flags=0x\(String($0.flags.rawValue, radix: 16))"
            }.joined(separator: "\n")
    }
}
