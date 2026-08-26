import CoreGraphics
import Foundation

/// Where macOS put the second screen, so the app can say so.
///
/// A virtual display is created without a position and macOS places it — in
/// practice to the left of the main screen. Nothing tells the user that, so the
/// cursor does not cross the edge they push against, and the reasonable
/// conclusion is that input forwarding is broken. It is not: the screen is on
/// the other side.
///
/// This is the same fault this project keeps shipping in different clothes. The
/// app knows a specific fact, shows a generic one, and the user is left to infer
/// the difference from behaviour. The fix is never a better guess downstream; it
/// is saying the thing that is already known.
public enum DisplayPlacement: String, Sendable, Equatable, CaseIterable {
    case left, right, above, below

    /// How it reads in the interface. Deliberately about the direction to push,
    /// because that is the action the reader is trying to take.
    public var describedForUser: String {
        switch self {
        case .left: return "Your second screen is to the left"
        case .right: return "Your second screen is to the right"
        case .above: return "Your second screen is above this one"
        case .below: return "Your second screen is below this one"
        }
    }

    /// Where macOS placed `secondary` relative to `main`.
    ///
    /// Whichever axis is more separated wins. A display can be offset on both —
    /// slightly above and far to the left is normally described as "to the
    /// left", because that is the edge the cursor actually crosses.
    public static func of(_ secondary: CGRect, relativeTo main: CGRect) -> DisplayPlacement {
        let dx = secondary.midX - main.midX
        let dy = secondary.midY - main.midY

        if abs(dx) >= abs(dy) {
            return dx < 0 ? .left : .right
        }
        // Cocoa's y axis points up, so a greater midY is physically higher.
        return dy > 0 ? .above : .below
    }
}
