import Foundation

/// Splitting what a person typed into a host and a port.
///
/// Exists so the Mac's viewer can offer ONE address field. A separate port box
/// was the last place either app put a port number in front of a user, and the
/// audit flagged the two exposed ports as one of the two findings that might be
/// bugs rather than design decisions.
///
/// It lives in the framework rather than beside the view because of the IPv6
/// case: a bare `fe80::1` is all colons, and splitting on the last one produces
/// a host and a "port" that are both nonsense. That mistake has already shipped
/// in this project once, as the receiver's "invalid authority" failure, and the
/// only reason it was ever caught was a user reporting it.
public enum ViewerAddress {
    /// Splits `host`, `host:port` or a bracketed IPv6 literal.
    ///
    /// Bare IPv6 has to be bracketed to be split at all — `fe80::1` is all
    /// colons — which is the same trap that produced "invalid authority" on the
    /// receiver when an mDNS result went in unbracketed.
    public static func parse(_ text: String, defaultPort: Int) -> (host: String, port: Int)? {
    if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()),
                (1...65535).contains(port)
            else { return nil }
            return (host, port)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        // More than one colon and no brackets: an unbracketed IPv6 literal.
        if parts.count > 2 { return (text, defaultPort) }
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65535).contains(port),
                !parts[0].isEmpty
            else { return nil }
            return (String(parts[0]), port)
        }
        return (text, defaultPort)
    }
}
