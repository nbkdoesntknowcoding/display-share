import AppKit
import Foundation

/// Checks GitHub Releases for a newer version.
///
/// **Deliberately not Sparkle.** Sparkle's value is silent, signed, automatic
/// installation — and this app ships unsigned, so an unattended self-replacing
/// binary is precisely the behaviour a user should distrust. It would also mean
/// managing a second signing keypair and hosting an appcast for a project whose
/// artifacts already live on GitHub Releases.
///
/// So this notifies and links; the user downloads deliberately. If Display Share
/// ever gets a Developer ID certificate, revisit — signed auto-update is a
/// different risk calculation.
public final class UpdateChecker: @unchecked Sendable {

    public struct Release: Equatable, Sendable {
        public let version: String
        public let url: URL
        public let notes: String
    }

    public enum Result: Equatable, Sendable {
        case upToDate
        /// No releases published yet — the normal state before the first one,
        /// and not worth showing the user as an error.
        case noReleases
        case updateAvailable(Release)
        case failed(String)
    }

    private let endpoint: URL
    private let currentVersion: String
    private let session: URLSession

    public init(
        repository: String = "nbkdoesntknowcoding/display-share",
        currentVersion: String? = nil,
        session: URLSession = .shared
    ) {
        self.endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        self.currentVersion =
            currentVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0.0.0"
        self.session = session
    }

    public func check() async -> Result {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("no HTTP response")
            }
            // 404 means the repo has no releases yet. That is expected before
            // the first release and must not surface as a failure.
            if http.statusCode == 404 { return .noReleases }
            guard http.statusCode == 200 else {
                return .failed("GitHub returned \(http.statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String,
                let urlString = json["html_url"] as? String,
                let url = URL(string: urlString)
            else {
                return .failed("unexpected response shape")
            }
            if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true {
                return .upToDate
            }

            let latest = Self.normalise(tag)
            guard Self.isNewer(latest, than: Self.normalise(currentVersion)) else {
                return .upToDate
            }
            return .updateAvailable(
                Release(version: latest, url: url, notes: (json["body"] as? String) ?? ""))
        } catch {
            return .failed("\(error.localizedDescription)")
        }
    }

    public func openReleasePage(_ release: Release) {
        NSWorkspace.shared.open(release.url)
    }

    // MARK: - Version comparison

    /// Strips a leading "v" so "v0.2.0" and "0.2.0" compare equal.
    static func normalise(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v
    }

    /// Numeric component comparison, so "0.10.0" is correctly newer than
    /// "0.9.0" — a plain string compare gets that backwards.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        // Drop any pre-release suffix: 1.2.3-beta.1 compares as 1.2.3.
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}
