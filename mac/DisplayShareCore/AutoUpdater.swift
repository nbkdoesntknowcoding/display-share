import CryptoKit
import Foundation

/// Downloads and applies updates at launch (Task 9.1).
///
/// **Why this is not simply "replace the app bundle".** macOS keys TCC
/// permissions to a bundle's *designated requirement*. The copy installed by
/// `install.sh` is signed with a self-signed machine identity, so its
/// requirement is `identifier + certificate root` and survives rebuilds. A CI
/// build is ad-hoc signed, so its requirement is a `cdhash` that differs every
/// time. Dropping a CI build over the installed app therefore changes the
/// requirement, and macOS silently revokes Screen Recording and Accessibility —
/// the failure this project already spent a long session escaping.
///
/// So the downloaded app is re-signed with the SAME local identity before it is
/// swapped in, and the resulting requirement is compared against the one already
/// granted. If they differ, the update is abandoned rather than applied: a
/// working old version beats a new one that cannot capture the screen.
public final class AutoUpdater: @unchecked Sendable {

    public enum Outcome: Equatable, Sendable {
        case upToDate
        /// Applied. `permissionsReset` is true only when the installed copy was
        /// ad-hoc signed, so its requirement could not be preserved and macOS
        /// will ask for Screen Recording and Accessibility once more.
        case applied(version: String, permissionsReset: Bool)
        /// Deliberately not attempted, with a reason worth showing.
        case skipped(String)
        case failed(String)
    }

    /// Name of the self-signed identity `install.sh` creates.
    public static let localIdentity = "Display Share Local Signing"

    private let repository: String
    private let currentVersion: String
    private let installedAppURL: URL
    private let session: URLSession

    public init(
        repository: String = "nbkdoesntknowcoding/display-share",
        currentVersion: String? = nil,
        installedAppURL: URL = Bundle.main.bundleURL,
        session: URLSession = .shared
    ) {
        self.repository = repository
        self.currentVersion =
            currentVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0.0.0"
        self.installedAppURL = installedAppURL
        self.session = session
    }

    // MARK: - Pure helpers (tested)

    /// Parses `shasum -a 256` output into filename -> hash.
    ///
    /// The names carry a `./` prefix because that is how the release job invokes
    /// shasum; stripping it here keeps the caller from having to know.
    public static func parseChecksums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let hash = String(parts[0]).lowercased()
            var name = String(parts[parts.count - 1])
            if name.hasPrefix("*") { name.removeFirst() }
            if name.hasPrefix("./") { name.removeFirst(2) }
            guard hash.count == 64 else { continue }
            result[name] = hash
        }
        return result
    }

    public struct Asset: Equatable, Sendable {
        public let name: String
        public let url: URL
    }

    /// Picks the .dmg and the checksum file from a release's assets.
    public static func selectAssets(_ assets: [Asset]) -> (dmg: Asset, sums: Asset)? {
        guard let dmg = assets.first(where: { $0.name.hasSuffix(".dmg") }),
            let sums = assets.first(where: { $0.name.hasPrefix("SHA256SUMS-macos") })
        else { return nil }
        return (dmg, sums)
    }

    // MARK: - Applying

    /// Checks for a newer release and installs it.
    ///
    /// `isStreaming` is honoured rather than advisory: replacing the binary of a
    /// running session tears down the virtual display mid-use, which from the
    /// user's side is indistinguishable from a crash.
    public func applyIfAvailable(isStreaming: Bool) async -> Outcome {
        await run(isStreaming: isStreaming, swapIn: true)
    }

    /// Everything except replacing the installed app.
    ///
    /// Exists so the dangerous half — that re-signing reproduces the designated
    /// requirement byte for byte — can be proven against a real release without
    /// touching the copy the user has already granted permissions to.
    public func dryRun() async -> Outcome {
        await run(isStreaming: false, swapIn: false)
    }

    private func run(isStreaming: Bool, swapIn: Bool) async -> Outcome {
        if isStreaming {
            return .skipped("a session is running")
        }
        // Without the local identity the re-signing step cannot preserve the
        // designated requirement, so applying would cost the user their
        // permissions. Refuse instead.
        guard Self.hasLocalIdentity() else {
            return .skipped("no local signing identity — reinstall with install.sh to enable updates")
        }
        // A build made from the repository reports whatever version the branch
        // happens to carry, which can be BEHIND a release while containing more
        // than it. Version comparison alone would quietly remove work, so ask
        // GitHub whether the release actually CONTAINS this build's commit.
        // If it does, replacing it loses nothing; if it does not, the build is
        // ahead of or beside the release and must be left alone.
        var sourceCommit: String?
        if let origin = Self.buildOrigin(installedAppURL) {
            guard let commit = Self.commit(fromOrigin: origin) else {
                return .skipped("built from source (\(origin)) — run install.sh to update")
            }
            sourceCommit = commit
        }

        do {
            guard let release = try await fetchLatest() else { return .upToDate }
            guard UpdateChecker.isNewer(release.version, than: currentVersion) else {
                return .upToDate
            }
            // For a source build the version number proves nothing, so the
            // release must be shown to contain this exact commit before it is
            // allowed to replace it.
            if let commit = sourceCommit {
                switch await containment(of: commit, in: release.version) {
                case .contained:
                    break
                case .notContained(let status):
                    return .skipped(
                        "built from source (\(commit)) and \(status) the release — run install.sh"
                    )
                case .unknown(let reason):
                    // Never guess in this direction: an unanswered question is
                    // a reason to leave a working app alone.
                    return .skipped("cannot confirm the release contains \(commit): \(reason)")
                }
            }
            guard let assets = Self.selectAssets(release.assets) else {
                return .failed("release \(release.version) has no .dmg and checksums")
            }

            let dmg = try await download(assets.dmg.url)
            defer { try? FileManager.default.removeItem(at: dmg) }

            let sumsData = try await downloadData(assets.sums.url)
            let expected = Self.parseChecksums(String(decoding: sumsData, as: UTF8.self))
            guard let wanted = expected[assets.dmg.name] else {
                return .failed("no checksum published for \(assets.dmg.name)")
            }
            let actual = try Self.sha256(of: dmg)
            guard actual == wanted else {
                // Either a corrupted download or a tampered artifact. Both are
                // reasons to stop, not to retry silently.
                return .failed("checksum mismatch for \(assets.dmg.name)")
            }

            let staged = try stageApp(fromDMG: dmg)
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }

            try resign(staged)
            let before = try Self.designatedRequirement(installedAppURL)
            let after = try Self.designatedRequirement(staged)
            var permissionsReset = false
            switch Self.classify(before: before, after: after) {
            case .unchanged:
                break
            case .stabilising:
                // The installed copy was ad-hoc, so its requirement is a hash
                // that changes on every build and could never have been
                // preserved. Moving to the machine identity costs one re-grant
                // and makes every future update seamless, so it is worth doing
                // once — but the caller must be able to say so.
                permissionsReset = true
            case .dangerous:
                return .failed(
                    "signing requirement would change, which resets permissions — update abandoned"
                )
            }

            if swapIn { try swap(staged) }
            return .applied(version: release.version, permissionsReset: permissionsReset)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Whether a release contains a given commit.
    public enum Containment: Equatable, Sendable {
        case contained
        /// The build sits ahead of, or beside, the release.
        case notContained(String)
        /// The question could not be answered — treated as "do not touch it".
        case unknown(String)
    }

    /// How a requirement would change if the update were applied.
    public enum RequirementChange: Equatable, Sendable {
        /// Identical — permissions carry over untouched. The normal case.
        case unchanged
        /// Ad-hoc becoming identity-signed: a one-time re-grant buys stability
        /// for every update afterwards.
        case stabilising
        /// Anything else, including identity-signed becoming something else.
        /// Applying this would cost permissions for no gain.
        case dangerous
    }

    /// True when a requirement is pinned to the binary's hash.
    ///
    /// An ad-hoc signature produces `cdhash H"..."`, which is different for every
    /// build, so permissions granted to one build never apply to the next. A
    /// certificate-backed requirement names the identifier and the root instead
    /// and is stable across rebuilds.
    public static func isAdHoc(_ requirement: String) -> Bool {
        requirement.contains("cdhash") && !requirement.contains("certificate root")
    }

    public static func classify(before: String, after: String) -> RequirementChange {
        if before == after { return .unchanged }
        // Only this one direction is worth a re-grant.
        if isAdHoc(before) && !isAdHoc(after) { return .stabilising }
        return .dangerous
    }

    /// Extracts the commit from the marker install.sh writes ("source <sha>").
    public static func commit(fromOrigin origin: String) -> String? {
        let token = origin.split(separator: " ").last.map(String.init) ?? ""
        // Hex and long enough to be a short sha; anything else is a marker
        // format this version does not understand, and guessing would be worse
        // than declining.
        let isHex = token.allSatisfy { $0.isHexDigit }
        return isHex && token.count >= 7 ? token : nil
    }

    /// Reads GitHub's compare status into a decision.
    ///
    /// **The status describes HEAD relative to BASE**, and the comparison here is
    /// `installedCommit...releaseTag`. So `ahead` means the RELEASE is ahead of
    /// the installed build — the release contains it, and replacing it loses
    /// nothing. `behind` means the opposite: the installed build carries commits
    /// the release does not.
    ///
    /// This reads backwards on first encounter and was in fact implemented
    /// backwards, which refused every safe update and, far worse, would have
    /// accepted exactly the case the guard exists to prevent.
    public static func containment(fromCompareStatus status: String) -> Containment {
        switch status {
        case "ahead", "identical": return .contained
        case "behind": return .notContained("is ahead of")
        case "diverged": return .notContained("has diverged from")
        default: return .unknown("unrecognised compare status \(status)")
        }
    }

    private func containment(of commit: String, in tag: String) async -> Containment {
        let path = "https://api.github.com/repos/\(repository)/compare/\(commit)...\(tag)"
        guard let url = URL(string: path) else { return .unknown("bad compare URL") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown("no HTTP response") }
            // 404 means the commit is not on this repository at all — a local
            // build that was never pushed.
            if http.statusCode == 404 { return .notContained("is not published in") }
            guard http.statusCode == 200 else { return .unknown("HTTP \(http.statusCode)") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let status = json["status"] as? String
            else { return .unknown("no status in the compare response") }
            if ProcessInfo.processInfo.environment["DS_UPDATE_TRACE"] != nil {
                print("compare \(commit)...\(tag) -> \(status)")
            }
            return Self.containment(fromCompareStatus: status)
        } catch {
            return .unknown("\(error.localizedDescription)")
        }
    }

    // MARK: - Steps

    private struct ReleaseInfo {
        /// tag_name, e.g. "v0.6.0". Used both as the version and as the git ref
        /// the compare API is asked about.
        let version: String
        let assets: [Asset]
    }

    private func fetchLatest() async throws -> ReleaseInfo? {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        // 404 = no releases yet, which is not an error worth surfacing.
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { return nil }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String
        else { return nil }
        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { entry -> Asset? in
            guard let name = entry["name"] as? String,
                let urlString = entry["browser_download_url"] as? String,
                let url = URL(string: urlString)
            else { return nil }
            return Asset(name: name, url: url)
        }
        return ReleaseInfo(version: tag, assets: assets)
    }

    private func download(_ url: URL) async throws -> URL {
        let (temporary, _) = try await session.download(from: url)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func downloadData(_ url: URL) async throws -> Data {
        let (data, _) = try await session.data(from: url)
        return data
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Streamed: a DMG is tens of megabytes and reading it whole to hash it
        // would be wasteful for no gain.
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Mounts the DMG, copies the app out, unmounts.
    private func stageApp(fromDMG dmg: URL) throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-mount-\(UUID().uuidString)")
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // -nobrowse so the volume does not appear in Finder mid-update.
        try Self.run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mountPoint.path,
        ])
        defer { try? Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) }

        let contents = try FileManager.default.contentsOfDirectory(
            at: mountPoint, includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.step("no .app inside the disk image")
        }
        let destination = staging.appendingPathComponent(app.lastPathComponent)
        // ditto rather than FileManager.copyItem: it preserves the extended
        // attributes and symlinks a signed bundle depends on.
        try Self.run("/usr/bin/ditto", [app.path, destination.path])
        return destination
    }

    /// Re-signs with the local identity, mirroring install.sh exactly.
    ///
    /// Nested code first, then the bundle — signing the outer bundle before its
    /// contents leaves the outer signature stale the moment the inner ones
    /// change.
    private func resign(_ app: URL) throws {
        let bundleID =
            Bundle(url: installedAppURL)?.bundleIdentifier ?? "in.theboringpeople.displayshare"

        // Entitlements are read back from the installed copy: the source plist
        // is not present at runtime, and re-signing without them would drop
        // whatever the granted app was built with.
        let entitlements = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-ent-\(UUID().uuidString).plist")
        // stdout ONLY, and trimmed to the plist. codesign writes its running
        // commentary to stderr, and the merged stream used elsewhere in this file
        // would splice that commentary into the plist — which codesign then
        // rejects as an unrecognised blob.
        var entitlementsArgument: [String] = []
        if let plist = try? Self.captureStandardOutput(
            "/usr/bin/codesign", ["-d", "--entitlements", ":-", "--xml", installedAppURL.path]
        ), let start = plist.range(of: "<?xml") ?? plist.range(of: "<plist") {
            try String(plist[start.lowerBound...]).write(
                to: entitlements, atomically: true, encoding: .utf8
            )
            entitlementsArgument = ["--entitlements", entitlements.path]
        }

        let framework = app.appendingPathComponent("Contents/Frameworks/DisplayShareCore.framework")
        if FileManager.default.fileExists(atPath: framework.path) {
            try? Self.run("/usr/bin/codesign", [
                "--force", "--sign", Self.localIdentity, "--identifier", "\(bundleID).core",
                framework.path,
            ])
        }
        let helper = app.appendingPathComponent("Contents/MacOS/vd_helper")
        if FileManager.default.fileExists(atPath: helper.path) {
            try? Self.run("/usr/bin/codesign", [
                "--force", "--sign", Self.localIdentity, "--identifier", "\(bundleID).vd-helper",
                helper.path,
            ])
        }
        try Self.run(
            "/usr/bin/codesign",
            ["--force", "--sign", Self.localIdentity, "--identifier", bundleID]
                + entitlementsArgument + [app.path]
        )
    }

    /// Replaces the installed app, keeping the old one until the move succeeds.
    private func swap(_ staged: URL) throws {
        let manager = FileManager.default
        let backup = installedAppURL.deletingLastPathComponent()
            .appendingPathComponent(".\(installedAppURL.lastPathComponent).old")
        try? manager.removeItem(at: backup)
        if manager.fileExists(atPath: installedAppURL.path) {
            try manager.moveItem(at: installedAppURL, to: backup)
        }
        do {
            try manager.moveItem(at: staged, to: installedAppURL)
        } catch {
            // Put the working copy back rather than leaving no app at all.
            try? manager.moveItem(at: backup, to: installedAppURL)
            throw error
        }
        try? manager.removeItem(at: backup)
    }

    // MARK: - Shell

    enum UpdateError: Error, CustomStringConvertible {
        case step(String)
        var description: String {
            switch self {
            case .step(let text): return text
            }
        }
    }

    /// Contents of the marker install.sh writes, or nil for a release build.
    static func buildOrigin(_ app: URL) -> String? {
        let marker = app.appendingPathComponent("Contents/Resources/build-origin.txt")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func hasLocalIdentity() -> Bool {
        (try? capture("/usr/bin/security", ["find-certificate", "-c", localIdentity]))?
            .contains("keychain") ?? false
    }

    public static func designatedRequirement(_ app: URL) throws -> String {
        let output = try capture("/usr/bin/codesign", ["-d", "--requirements", "-", app.path])
        guard let line = output.split(separator: "\n").first(where: { $0.contains("designated =>") })
        else { throw UpdateError.step("no designated requirement for \(app.lastPathComponent)") }
        return line.trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        try capture(launchPath, arguments)
    }

    /// Runs a tool and returns only its standard output.
    static func captureStandardOutput(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    public static func capture(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // codesign writes almost everything to stderr, including the
        // requirements it is asked to print.
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError.step(
                "\(URL(fileURLWithPath: launchPath).lastPathComponent) failed: \(output.prefix(200))"
            )
        }
        return output
    }
}
