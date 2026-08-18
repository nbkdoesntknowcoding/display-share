import Foundation

/// Sender-side decoding of forwarded input (protocol/SPEC.md §4.10).
///
/// Task 5.1 stops at decode + ordering + logging; Task 5.2 turns these into
/// CGEvents. Keeping them apart means the wire format can be validated before
/// anything is allowed to drive the Mac.
public struct ForwardedInputEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case move, down, up, scroll, key
        /// Relative delta in device pixels, used once the pointer has escaped
        /// the second screen (SPEC §3.1).
        case moverel
    }

    public struct Modifiers: Codable, Equatable, Sendable {
        public var shift: Bool = false
        public var ctrl: Bool = false
        public var alt: Bool = false
        public var meta: Bool = false
    }

    public var k: Kind
    /// Receiver-side milliseconds. Ordering only — NOT comparable to §3.2.
    public var t: Int
    /// Normalised 0-1 within the displayed video rect.
    public var x: Double?
    public var y: Double?
    public var b: Int?
    public var dx: Double?
    public var dy: Double?
    public var code: String?
    public var down: Bool?
    public var mods: Modifiers?

    public init(k: Kind, t: Int) {
        self.k = k
        self.t = t
    }
}
