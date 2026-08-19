import XCTest

@testable import DisplayShareCore

/// Task 9.1. The parsing here decides whether a downloaded artifact is trusted,
/// so a permissive bug would be a security bug rather than a cosmetic one.
final class AutoUpdaterTests: XCTestCase {

    func testChecksumsParseTheReleaseJobsFormat() {
        // Exactly what `shasum -a 256 ./*.dmg` writes, dot-slash and all.
        let text = """
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  ./DisplayShare-0.3.0.dmg
            """
        let map = AutoUpdater.parseChecksums(text)
        XCTAssertEqual(map["DisplayShare-0.3.0.dmg"], "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testBinaryModeStarAndPlainNamesBothWork() {
        let map = AutoUpdater.parseChecksums("""
            aa\(String(repeating: "b", count: 62))  *one.dmg
            cc\(String(repeating: "d", count: 62))  two.dmg
            """)
        XCTAssertEqual(map.count, 2)
        XCTAssertNotNil(map["one.dmg"])
        XCTAssertNotNil(map["two.dmg"])
    }

    func testMalformedLinesAreIgnoredRatherThanTrusted() {
        // A short hash must not be accepted: it would make a mismatch look like
        // a match for any artifact whose name happened to line up.
        let map = AutoUpdater.parseChecksums("""
            deadbeef  short.dmg
            not a checksum line at all

            """)
        XCTAssertTrue(map.isEmpty)
    }

    func testAssetSelectionFindsTheDmgAndChecksums() {
        let assets = [
            AutoUpdater.Asset(name: "latest.json", url: URL(string: "https://x/1")!),
            AutoUpdater.Asset(name: "SHA256SUMS-windows.txt", url: URL(string: "https://x/2")!),
            AutoUpdater.Asset(name: "DisplayShare-0.3.0.dmg", url: URL(string: "https://x/3")!),
            AutoUpdater.Asset(name: "SHA256SUMS-macos.txt", url: URL(string: "https://x/4")!),
        ]
        let chosen = AutoUpdater.selectAssets(assets)
        XCTAssertEqual(chosen?.dmg.name, "DisplayShare-0.3.0.dmg")
        // Must not pick the Windows checksums, which are also SHA256SUMS-*.
        XCTAssertEqual(chosen?.sums.name, "SHA256SUMS-macos.txt")
    }

    func testWindowsOnlyReleaseIsRejected() {
        let assets = [
            AutoUpdater.Asset(name: "setup.exe", url: URL(string: "https://x/1")!),
            AutoUpdater.Asset(name: "SHA256SUMS-windows.txt", url: URL(string: "https://x/2")!),
        ]
        XCTAssertNil(AutoUpdater.selectAssets(assets))
    }

    func testShaMatchesTheSystemTool() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-sha-\(UUID().uuidString).bin")
        try Data((0..<5000).map { UInt8($0 % 251) }).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let ours = try AutoUpdater.sha256(of: file)
        let theirs = try AutoUpdater.capture("/usr/bin/shasum", ["-a", "256", file.path])
            .split(separator: " ").first.map(String.init)
        XCTAssertEqual(ours, theirs)
    }

    // MARK: - Requirement changes (t-700)

    private let adHoc = #"designated => cdhash H"b4402bc6ff1a2c3d4e5f60718293a4b5c6d7e8f9""#
    private let identity =
        #"designated => identifier "in.theboringpeople.displayshare" and certificate root = H"8fa250b1""#

    func testAdHocIsRecognisedByItsHashPin() {
        XCTAssertTrue(AutoUpdater.isAdHoc(adHoc))
        // A certificate-backed requirement is stable across rebuilds even
        // though it may also mention a hash elsewhere.
        XCTAssertFalse(AutoUpdater.isAdHoc(identity))
    }

    func testIdenticalRequirementsNeedNoRegrant() {
        XCTAssertEqual(AutoUpdater.classify(before: identity, after: identity), .unchanged)
    }

    func testAdHocToIdentityIsWorthOneRegrant() {
        // The installed copy's requirement could never have been preserved, so
        // one re-grant buys stability for every update afterwards.
        XCTAssertEqual(AutoUpdater.classify(before: adHoc, after: identity), .stabilising)
    }

    func testLosingACertificateBackedRequirementIsRefused() {
        // The dangerous direction: permissions already granted would be dropped
        // for nothing in return.
        XCTAssertEqual(AutoUpdater.classify(before: identity, after: adHoc), .dangerous)
        let otherIdentity = identity.replacingOccurrences(of: "8fa250b1", with: "deadbeef")
        XCTAssertEqual(AutoUpdater.classify(before: identity, after: otherIdentity), .dangerous)
    }

    // MARK: - Source builds

    func testCommitIsReadFromTheInstallMarker() {
        XCTAssertEqual(AutoUpdater.commit(fromOrigin: "source 57c2cff"), "57c2cff")
        XCTAssertEqual(
            AutoUpdater.commit(fromOrigin: "source 4d3f1389ab2c"), "4d3f1389ab2c")
    }

    func testUnreadableMarkersAreNotGuessedAt() {
        // A marker this version does not understand must leave the app alone
        // rather than be interpreted optimistically.
        XCTAssertNil(AutoUpdater.commit(fromOrigin: "source"))
        XCTAssertNil(AutoUpdater.commit(fromOrigin: "source not-a-sha"))
        XCTAssertNil(AutoUpdater.commit(fromOrigin: "source abc"))
        XCTAssertNil(AutoUpdater.commit(fromOrigin: ""))
    }

    func testOnlyAContainedCommitMayBeReplaced() {
        // The comparison is installedCommit...releaseTag, and the status
        // describes HEAD relative to BASE. So "ahead" means the RELEASE is ahead
        // of the installed build — it contains it. Verified against the live API:
        // a303bde...v0.7.1 reports "ahead", and a303bde is in fact in v0.7.1.
        XCTAssertEqual(AutoUpdater.containment(fromCompareStatus: "ahead"), .contained)
        XCTAssertEqual(AutoUpdater.containment(fromCompareStatus: "identical"), .contained)
    }

    func testABuildAheadOfTheReleaseIsLeftAlone() {
        // "behind" = the release is behind the installed build, so that build
        // holds commits the release does not. Replacing it deletes unreleased
        // work, which is the entire reason this guard exists. Reading the status
        // the other way round makes this case pass silently.
        guard case .notContained = AutoUpdater.containment(fromCompareStatus: "behind") else {
            return XCTFail("a build ahead of the release must not be replaced")
        }
        guard case .notContained = AutoUpdater.containment(fromCompareStatus: "diverged") else {
            return XCTFail("a diverged build must not be replaced")
        }
    }

    func testAnUnrecognisedStatusIsTreatedAsUnknownNotAsSafe() {
        // Failing open here would replace a build on any API change.
        guard case .unknown = AutoUpdater.containment(fromCompareStatus: "something-new") else {
            return XCTFail("an unrecognised status must not count as contained")
        }
    }

    func testStreamingSessionIsNotInterrupted() async {
        // Replacing the binary mid-session tears down the virtual display, which
        // looks like a crash from the user's side.
        let outcome = await AutoUpdater().applyIfAvailable(isStreaming: true)
        XCTAssertEqual(outcome, .skipped("a session is running"))
    }
}
