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

    func testStreamingSessionIsNotInterrupted() async {
        // Replacing the binary mid-session tears down the virtual display, which
        // looks like a crash from the user's side.
        let outcome = await AutoUpdater().applyIfAvailable(isStreaming: true)
        XCTAssertEqual(outcome, .skipped("a session is running"))
    }
}
