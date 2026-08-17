import XCTest

@testable import DisplayShareCore

/// Task 7.2. Version comparison is where update checks quietly go wrong — a
/// string compare says "0.10.0" < "0.9.0", which would strand users one release
/// behind forever.
final class UpdateCheckerTests: XCTestCase {

    func testStripsLeadingV() {
        XCTAssertEqual(UpdateChecker.normalise("v0.2.0"), "0.2.0")
        XCTAssertEqual(UpdateChecker.normalise("V1.0.0"), "1.0.0")
        XCTAssertEqual(UpdateChecker.normalise(" 0.3.1 "), "0.3.1")
    }

    func testDetectsNewerVersions() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.1", than: "0.1.0"))
    }

    func testSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
    }

    func testOlderVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "1.0.0"))
    }

    /// The one a string comparison gets wrong.
    func testDoubleDigitComponentsCompareNumerically() {
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.0", than: "0.10.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.20.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.10", than: "0.2.9"))
    }

    func testDifferingComponentCountsAreHandled() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2", than: "0.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1", than: "0.9.9"))
    }

    /// A pre-release tag must not read as a different number.
    func testPreReleaseSuffixIsIgnoredForOrdering() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0-beta.1", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.0-rc.1", than: "1.0.0"))
    }

    func testGarbageDoesNotCrashOrFalselyReportAnUpdate() {
        XCTAssertFalse(UpdateChecker.isNewer("", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("not-a-version", than: "0.1.0"))
    }
}
