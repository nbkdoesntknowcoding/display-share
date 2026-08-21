import XCTest

@testable import DisplayShareCore

/// When a running copy looks for a new version.
///
/// The bug these exist for: the updater relaunches the app it installs with
/// `--updated`, and the guard that skipped the immediate check also skipped the
/// line that scheduled the repeating one. A copy that updated itself once never
/// looked again — so a menu bar app left running froze on that version, and
/// reinstalling by hand was the only way forward.
///
/// Nothing about that is visible in a build, in a test run, or in a session
/// shorter than the check interval. It needs an assertion.
final class UpdateSchedulingTests: XCTestCase {

    private let installed = "/Applications/DisplayShare.app"

    // MARK: - The bug

    /// The regression, stated directly.
    func testACopyTheUpdaterRelaunchedStillKeepsChecking() {
        let plan = UpdateScheduling.plan(
            bundlePath: installed, arguments: ["DisplayShare", "--updated"])
        XCTAssertFalse(plan.checkNow, "it would only rediscover the version it just installed")
        XCTAssertTrue(
            plan.scheduleRepeatingCheck,
            "an updated copy must keep looking — skipping this froze it for its whole lifetime"
        )
    }

    /// Whatever else changes, every installed copy ends up on a timer.
    func testEveryInstalledCopySchedulesTheRepeatingCheck() {
        for arguments in [
            ["DisplayShare"],
            ["DisplayShare", "--updated"],
            ["DisplayShare", "--viewer"],
            ["DisplayShare", "--updated", "--viewer"],
        ] {
            let plan = UpdateScheduling.plan(bundlePath: installed, arguments: arguments)
            XCTAssertTrue(
                plan.scheduleRepeatingCheck,
                "no installed copy may stop checking: \(arguments)")
        }
    }

    // MARK: - Normal launch

    func testANormalLaunchChecksImmediatelyAndKeepsChecking() {
        let plan = UpdateScheduling.plan(bundlePath: installed, arguments: ["DisplayShare"])
        XCTAssertTrue(plan.checkNow)
        XCTAssertTrue(plan.scheduleRepeatingCheck)
        XCTAssertFalse(plan.notifyOnly)
    }

    // MARK: - Builds from a working copy

    /// A release must never overwrite the copy someone is developing against.
    func testADevelopmentBuildIsOnlyToldThatAVersionExists() {
        for path in [
            "/Users/someone/Projects/Display Share/mac/build/Debug/DisplayShare.app",
            "/Users/someone/Downloads/DisplayShare.app",
            "/Volumes/DisplayShare/DisplayShare.app",
        ] {
            let plan = UpdateScheduling.plan(bundlePath: path, arguments: ["DisplayShare"])
            XCTAssertTrue(plan.notifyOnly, "\(path) must not be replaced")
            XCTAssertFalse(plan.checkNow, "\(path)")
            XCTAssertFalse(plan.scheduleRepeatingCheck, "\(path)")
        }
    }

    /// The DMG mounts at /Volumes; running from there and updating in place
    /// would write into a read-only image.
    func testRunningFromTheDiskImageIsNotAnInstallation() {
        let plan = UpdateScheduling.plan(
            bundlePath: "/Volumes/DisplayShare 0.14.1/DisplayShare.app",
            arguments: ["DisplayShare"])
        XCTAssertTrue(plan.notifyOnly)
    }

    // MARK: - Cadence

    func testTheIntervalIsSixHours() {
        XCTAssertEqual(UpdateScheduling.interval, 6 * 60 * 60)
    }

    /// The flag the updater passes and the flag the app reads are the same
    /// string. Two spellings would make the app re-check on every relaunch,
    /// which is the loop the guard exists to prevent.
    func testTheRelaunchFlagIsShared() {
        XCTAssertEqual(UpdateScheduling.relaunchedFlag, "--updated")
        let plan = UpdateScheduling.plan(
            bundlePath: installed,
            arguments: ["DisplayShare", UpdateScheduling.relaunchedFlag])
        XCTAssertFalse(plan.checkNow)
    }
}
