import XCTest

@testable import DisplayShareCore

/// One address field, and the parsing that makes it possible (Command 5).
///
/// The Mac's viewer used to ask for a host and a port in two boxes — the last
/// place either app put a port number in front of a user. Collapsing them means
/// splitting the text, and splitting an address is where this project has
/// already shipped a bug: an unbracketed IPv6 literal from mDNS produced
/// "invalid authority" on the receiver, and a user found it, not a test.
final class ViewerAddressTests: XCTestCase {

    private let fallback = 7879

    private func parse(_ text: String) -> (host: String, port: Int)? {
        ViewerAddress.parse(text, defaultPort: fallback)
    }

    // MARK: - The common case

    func testABareAddressTakesTheDefaultPort() {
        let result = parse("192.168.1.42")
        XCTAssertEqual(result?.host, "192.168.1.42")
        XCTAssertEqual(result?.port, fallback)
    }

    func testAHostnameTakesTheDefaultPort() {
        XCTAssertEqual(parse("studio-pc.local")?.host, "studio-pc.local")
        XCTAssertEqual(parse("studio-pc.local")?.port, fallback)
    }

    func testAnExplicitPortIsHonoured() {
        let result = parse("192.168.1.42:9000")
        XCTAssertEqual(result?.host, "192.168.1.42")
        XCTAssertEqual(result?.port, 9000)
    }

    // MARK: - IPv6

    /// The trap. Every character after the first colon is part of the address,
    /// not a port, and a splitter that does not know this produces a host and a
    /// port that are both wrong.
    func testAnUnbracketedIPv6LiteralIsAnAddressAndNotAPort() {
        let result = parse("fe80::1")
        XCTAssertEqual(result?.host, "fe80::1")
        XCTAssertEqual(result?.port, fallback)
    }

    func testALongUnbracketedIPv6LiteralSurvivesIntact() {
        let text = "2001:db8:85a3::8a2e:370:7334"
        XCTAssertEqual(parse(text)?.host, text)
        XCTAssertEqual(parse(text)?.port, fallback)
    }

    func testABracketedIPv6LiteralDropsItsBrackets() {
        XCTAssertEqual(parse("[fe80::1]")?.host, "fe80::1")
        XCTAssertEqual(parse("[fe80::1]")?.port, fallback)
    }

    func testABracketedIPv6LiteralWithAPort() {
        let result = parse("[2001:db8::1]:9000")
        XCTAssertEqual(result?.host, "2001:db8::1")
        XCTAssertEqual(result?.port, 9000)
    }

    // MARK: - Rejections

    /// Rejected rather than silently coerced: a wrong port produces a
    /// connection failure somewhere far from the field that caused it.
    func testAnOutOfRangePortIsRejected() {
        XCTAssertNil(parse("192.168.1.42:0"))
        XCTAssertNil(parse("192.168.1.42:70000"))
    }

    func testANonNumericPortIsRejected() {
        XCTAssertNil(parse("192.168.1.42:abc"))
    }

    func testAMissingHostIsRejected() {
        XCTAssertNil(parse(":9000"))
    }

    func testAnUnclosedBracketIsRejected() {
        XCTAssertNil(parse("[fe80::1"))
    }

    func testTrailingRubbishAfterTheBracketIsRejected() {
        XCTAssertNil(parse("[fe80::1]9000"))
    }

    // MARK: - Round trip

    /// Discovery writes its result back into the same field, so what it writes
    /// has to be something this function can read again — otherwise editing a
    /// discovered address and reconnecting fails.
    func testWhatDiscoveryWritesCanBeParsedBack() {
        for written in ["192.168.1.42:7879", "[fe80::1]:7879", "studio-pc.local:7879"] {
            XCTAssertNotNil(parse(written), "discovery would write \(written)")
        }
        XCTAssertEqual(parse("[fe80::1]:7879")?.host, "fe80::1")
        XCTAssertEqual(parse("192.168.1.42:7879")?.port, 7879)
    }
}
