import Foundation

/// When a running copy looks for a new version.
///
/// This is a value rather than a sequence of early returns inside
/// `applicationDidFinishLaunching`, because the bug it encodes was invisible
/// there and is invisible in testing:
///
/// The updater relaunches the app it just installed with `--updated`, so the
/// new process does not immediately rediscover the version it is already
/// running. That guard `return`ed — and the line that scheduled the repeating
/// check sat below it. **A copy that had updated itself once never checked
/// again for the rest of its life.** The Windows receiver checks on every
/// launch and kept pace; the Mac is a menu bar app people leave running for
/// days, so it silently froze on whatever version it happened to land on, and
/// the only cure was quitting it or reinstalling by hand.
///
/// Skipping the immediate check is right. Skipping the timer with it was not.
public struct UpdatePlan: Equatable, Sendable {
    /// Look for a new version straight away.
    public let checkNow: Bool
    /// Keep looking, for as long as this process runs.
    public let scheduleRepeatingCheck: Bool
    /// Report that a version exists but never replace anything.
    public let notifyOnly: Bool
}

public enum UpdateScheduling {
    /// How often a long-running copy looks again.
    ///
    /// Launch alone is not enough for a menu bar app: three releases once
    /// shipped past a copy that had been up for four hours.
    public static let interval: TimeInterval = 6 * 60 * 60

    /// Marks the process the updater started, so it does not immediately
    /// rediscover the version it just installed.
    public static let relaunchedFlag = "--updated"

    public static func plan(bundlePath: String, arguments: [String]) -> UpdatePlan {
        // Only ever replace a real installation. A build running out of a
        // developer's build directory must not be overwritten by a release —
        // but it should still say when one exists.
        guard bundlePath.hasPrefix("/Applications/") else {
            return UpdatePlan(checkNow: false, scheduleRepeatingCheck: false, notifyOnly: true)
        }

        let relaunched = arguments.contains(relaunchedFlag)
        return UpdatePlan(
            checkNow: !relaunched,
            // Always. This is the line the early return used to skip.
            scheduleRepeatingCheck: true,
            notifyOnly: false
        )
    }
}
