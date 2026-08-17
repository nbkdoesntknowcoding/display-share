import CryptoKit
import Foundation

/// Remembers which receivers are allowed to connect.
///
/// A 4-digit PIN is only 10,000 possibilities, so the security here rests on
/// rate limiting rather than on the PIN's entropy: three attempts per minute per
/// device makes brute force impractical while keeping the PIN short enough to
/// read off a screen and type. Modelled on Sunshine's UX (read for UX only —
/// Sunshine is GPL-3.0 and no source was copied).
public final class PairingStore: @unchecked Sendable {

    public struct PairedDevice: Codable, Equatable, Sendable {
        public var deviceId: String
        public var deviceName: String
        /// Stored as a SHA-256 hash, never in the clear — the file is readable by
        /// the user's account and a leaked token would grant display access.
        public var tokenHash: String
        public var pairedAt: Date
        public var lastSeen: Date?
    }

    private struct Attempt {
        var count: Int
        var windowStart: Date
    }

    private let url: URL
    private let lock = NSLock()
    private var devices: [String: PairedDevice] = [:]
    private var attempts: [String: Attempt] = [:]

    /// Active PIN, non-nil only while a pairing request is outstanding.
    public private(set) var activePIN: String?
    /// Raised when a PIN is generated, so the UI can show it.
    public var onPINChanged: ((String?) -> Void)?

    public static let maxAttemptsPerWindow = 3
    public static let attemptWindow: TimeInterval = 60

    public init(url: URL? = nil) {
        self.url =
            url
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("DisplayShare", isDirectory: true)
                .appendingPathComponent("paired-devices.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: PairedDevice].self, from: data)
        else { return }
        devices = decoded
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(devices) else { return }
        try? data.write(to: url, options: .atomic)
        // Owner-only: this file decides who may drive the display.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Queries

    public var pairedDevices: [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return Array(devices.values).sorted { $0.pairedAt > $1.pairedAt }
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison, so a timing side channel cannot leak the token.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<lhs.count { difference |= lhs[i] ^ rhs[i] }
        return difference == 0
    }

    public func isAuthorised(deviceId: String?, token: String?) -> Bool {
        guard let deviceId, let token else { return false }
        lock.lock()
        let device = devices[deviceId]
        lock.unlock()
        guard let device else { return false }
        guard Self.constantTimeEquals(device.tokenHash, Self.hash(token)) else { return false }

        lock.lock()
        devices[deviceId]?.lastSeen = Date()
        lock.unlock()
        persist()
        return true
    }

    // MARK: - Pairing

    /// Starts a pairing attempt and returns the PIN the user must type.
    @discardableResult
    public func beginPairing() -> String {
        // 4 digits, uniformly distributed, from the system CSPRNG.
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        lock.lock()
        activePIN = pin
        lock.unlock()
        onPINChanged?(pin)
        return pin
    }

    public func cancelPairing() {
        lock.lock()
        activePIN = nil
        lock.unlock()
        onPINChanged?(nil)
    }

    public enum PairResult: Equatable {
        case paired(token: String)
        case wrongPIN
        case rateLimited(retryAfter: TimeInterval)
        case noPairingInProgress
    }

    public func completePairing(deviceId: String, deviceName: String, pin: String) -> PairResult {
        lock.lock()

        // Rate limit BEFORE checking the PIN, so a wrong guess still costs an attempt.
        let now = Date()
        var attempt = attempts[deviceId] ?? Attempt(count: 0, windowStart: now)
        if now.timeIntervalSince(attempt.windowStart) > Self.attemptWindow {
            attempt = Attempt(count: 0, windowStart: now)
        }
        if attempt.count >= Self.maxAttemptsPerWindow {
            let retryAfter = Self.attemptWindow - now.timeIntervalSince(attempt.windowStart)
            attempts[deviceId] = attempt
            lock.unlock()
            return .rateLimited(retryAfter: max(0, retryAfter))
        }
        attempt.count += 1
        attempts[deviceId] = attempt

        guard let expected = activePIN else {
            lock.unlock()
            return .noPairingInProgress
        }
        guard Self.constantTimeEquals(expected, pin) else {
            lock.unlock()
            return .wrongPIN
        }

        // Correct PIN: mint a token and clear the attempt counter.
        let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            .map { String(format: "%02x", $0) }.joined()
        devices[deviceId] = PairedDevice(
            deviceId: deviceId, deviceName: deviceName,
            tokenHash: Self.hash(token), pairedAt: Date(), lastSeen: Date())
        attempts[deviceId] = nil
        activePIN = nil
        lock.unlock()

        persist()
        onPINChanged?(nil)
        return .paired(token: token)
    }

    public func forget(deviceId: String) {
        lock.lock()
        devices[deviceId] = nil
        lock.unlock()
        persist()
    }

    public func forgetAll() {
        lock.lock()
        devices.removeAll()
        lock.unlock()
        persist()
    }
}
