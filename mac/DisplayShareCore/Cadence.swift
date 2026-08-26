import Foundation

/// Choosing a capture rate the receiver's panel can actually show evenly.
///
/// A frame rate that does not divide the panel's refresh rate cannot be
/// displayed at a steady cadence, however healthy the link is. Send 60fps to a
/// 144Hz panel and each frame is held for 2.4 refreshes, which the panel rounds
/// to alternating 2 and 3 — a beat pattern that reads as stutter even though no
/// frame was lost, nothing was late, and every number in the HUD looks perfect.
///
/// It is worth being clear about what this trades. Snapping 60 down to 48 on
/// that panel sends fewer frames, and fewer frames is usually worse. Here it is
/// better, because the alternative is not 60 smooth frames — it is 60 frames
/// displayed unevenly. Evenness is what the eye reads as smooth; the count is
/// what a spec sheet reads.
///
/// Only when the two are close, though. A panel whose divisors are all far from
/// what was asked for is a panel where snapping would cost more than the
/// unevenness does, so the request stands and the judder is accepted.
public enum Cadence {

    /// How far below the requested rate a divisor may sit and still be worth
    /// taking. Beyond this the frame-rate cut costs more than the uneven
    /// cadence it fixes.
    public static let tolerance = 0.2

    /// A frame rate the panel can show evenly, at or below `preferred`.
    ///
    /// At or below deliberately: raising the rate to reach a divisor would cost
    /// encode time and bandwidth the user did not ask for, on a machine that
    /// may already be struggling.
    ///
    /// Returns `preferred` unchanged when the refresh rate is unknown, when it
    /// already divides evenly, or when no divisor is close enough to be worth
    /// the loss.
    public static func rate(preferred: Int, panelRefresh: Int) -> Int {
        // An unknown or nonsensical panel is not evidence to act on. Receivers
        // that report nothing get exactly what was asked for.
        guard preferred > 0, panelRefresh > 0 else { return preferred }

        // Already even — the overwhelmingly common case, since 60 into 120 and
        // 30 into 60 are what most pairs of machines actually are.
        if panelRefresh % preferred == 0 { return preferred }

        // A rate above the panel's own refresh cannot be shown evenly by any
        // means; the panel is the ceiling.
        if preferred > panelRefresh { return panelRefresh }

        guard let best = divisors(of: panelRefresh).filter({ $0 <= preferred }).max() else {
            return preferred
        }
        let loss = Double(preferred - best) / Double(preferred)
        return loss <= tolerance ? best : preferred
    }

    /// Whether a rate can be shown evenly on a given panel. Reported so the
    /// interface can say why a chosen number was not the number used.
    public static func isEven(rate: Int, panelRefresh: Int) -> Bool {
        guard rate > 0, panelRefresh > 0 else { return true }
        return panelRefresh % rate == 0
    }

    private static func divisors(of value: Int) -> [Int] {
        (1...value).filter { value % $0 == 0 }
    }
}
