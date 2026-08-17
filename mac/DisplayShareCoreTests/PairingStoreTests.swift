import XCTest

@testable import DisplayShareCore

/// Task 4.1. A 4-digit PIN has only 10,000 possibilities, so rate limiting is
/// the actual security control here — these tests exist to keep it honest.
final class PairingStoreTests: XCTestCase {

    private var storeURL: URL!
    private var store: PairingStore!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-pairing-\(UUID().uuidString).json")
        store = PairingStore(url: storeURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL)
        super.tearDown()
    }

    func testUnpairedDeviceIsNotAuthorised() {
        XCTAssertFalse(store.isAuthorised(deviceId: "dev-1", token: "anything"))
        XCTAssertFalse(store.isAuthorised(deviceId: nil, token: nil))
    }

    func testCorrectPINPairsAndTokenAuthorises() {
        let pin = store.beginPairing()
        XCTAssertEqual(pin.count, 4)

        guard case .paired(let token) = store.completePairing(
            deviceId: "dev-1", deviceName: "VIVOBOOK", pin: pin)
        else { return XCTFail("expected pairing to succeed") }

        XCTAssertFalse(token.isEmpty)
        XCTAssertTrue(store.isAuthorised(deviceId: "dev-1", token: token))
        // The PIN is single-use: it clears once redeemed.
        XCTAssertNil(store.activePIN)
    }

    func testTokenIsBoundToTheDeviceThatEarnedIt() {
        let pin = store.beginPairing()
        guard case .paired(let token) = store.completePairing(
            deviceId: "dev-1", deviceName: "A", pin: pin) else { return XCTFail() }

        // A different device presenting a stolen token must be refused.
        XCTAssertFalse(store.isAuthorised(deviceId: "dev-2", token: token))
        XCTAssertTrue(store.isAuthorised(deviceId: "dev-1", token: token))
    }

    func testWrongPINIsRejected() {
        let pin = store.beginPairing()
        let wrong = pin == "0000" ? "1111" : "0000"
        XCTAssertEqual(
            store.completePairing(deviceId: "dev-1", deviceName: "A", pin: wrong), .wrongPIN)
        // Still unpaired, and the PIN remains live for a legitimate retry.
        XCTAssertFalse(store.isAuthorised(deviceId: "dev-1", token: "x"))
        XCTAssertNotNil(store.activePIN)
    }

    /// The core protection: three wrong guesses per minute, then refusal.
    /// Without this, 10,000 PINs fall in seconds.
    func testRateLimitBlocksBruteForce() {
        let pin = store.beginPairing()
        let wrong = pin == "0000" ? "1111" : "0000"

        for attempt in 1...PairingStore.maxAttemptsPerWindow {
            XCTAssertEqual(
                store.completePairing(deviceId: "dev-1", deviceName: "A", pin: wrong), .wrongPIN,
                "attempt \(attempt) should be evaluated")
        }

        // Fourth attempt is refused without even checking the PIN.
        guard case .rateLimited = store.completePairing(
            deviceId: "dev-1", deviceName: "A", pin: wrong)
        else { return XCTFail("expected rate limiting") }

        // And crucially, the CORRECT pin is refused too while limited —
        // otherwise an attacker just keeps guessing until they get it right.
        guard case .rateLimited = store.completePairing(
            deviceId: "dev-1", deviceName: "A", pin: pin)
        else { return XCTFail("rate limit must apply to correct PINs as well") }
    }

    func testRateLimitIsPerDevice() {
        let pin = store.beginPairing()
        let wrong = pin == "0000" ? "1111" : "0000"
        for _ in 1...PairingStore.maxAttemptsPerWindow {
            _ = store.completePairing(deviceId: "attacker", deviceName: "A", pin: wrong)
        }
        // A different, legitimate device is unaffected by the attacker's attempts.
        guard case .paired = store.completePairing(
            deviceId: "honest", deviceName: "B", pin: pin)
        else { return XCTFail("a separate device should not inherit the rate limit") }
    }

    func testPairingWithoutAnActivePINIsRejected() {
        XCTAssertEqual(
            store.completePairing(deviceId: "dev-1", deviceName: "A", pin: "1234"),
            .noPairingInProgress)
    }

    func testPairingsSurviveARestart() {
        let pin = store.beginPairing()
        guard case .paired(let token) = store.completePairing(
            deviceId: "dev-1", deviceName: "VIVOBOOK", pin: pin) else { return XCTFail() }

        // A fresh store over the same file is what the next app launch sees.
        let reloaded = PairingStore(url: storeURL)
        XCTAssertTrue(reloaded.isAuthorised(deviceId: "dev-1", token: token))
        XCTAssertEqual(reloaded.pairedDevices.first?.deviceName, "VIVOBOOK")
    }

    /// The token must never be recoverable from disk.
    func testTokenIsStoredHashedNotInClear() throws {
        let pin = store.beginPairing()
        guard case .paired(let token) = store.completePairing(
            deviceId: "dev-1", deviceName: "A", pin: pin) else { return XCTFail() }

        let contents = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertFalse(contents.contains(token), "the raw token must not be on disk")
        XCTAssertTrue(contents.contains("tokenHash"))
    }

    func testForgetRevokesAccess() {
        let pin = store.beginPairing()
        guard case .paired(let token) = store.completePairing(
            deviceId: "dev-1", deviceName: "A", pin: pin) else { return XCTFail() }
        XCTAssertTrue(store.isAuthorised(deviceId: "dev-1", token: token))

        store.forget(deviceId: "dev-1")
        XCTAssertFalse(store.isAuthorised(deviceId: "dev-1", token: token))
        XCTAssertTrue(store.pairedDevices.isEmpty)
    }

    func testGeneratedPINsAreNotAllTheSame() {
        // A constant PIN would defeat the whole mechanism.
        var seen = Set<String>()
        for _ in 0..<40 { seen.insert(store.beginPairing()) }
        XCTAssertGreaterThan(seen.count, 5, "PINs look insufficiently random")
    }
}
