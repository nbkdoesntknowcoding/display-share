// GENERATED FROM design/tokens.json — DO NOT EDIT.
// Run `node design/generate-swift.mjs` after changing tokens.json.
// CI fails if this file does not match the generator's output.
import SwiftUI

/// The colours both apps share. Never hardcode a hex value in app code.
public enum DSColor {
    /// #0A0A0C
    public static let bg = Color(red: 0.0392, green: 0.0392, blue: 0.0471)
    /// #141418
    public static let surface = Color(red: 0.0784, green: 0.0784, blue: 0.0941)
    /// #1D1D23
    public static let surfaceRaised = Color(red: 0.1137, green: 0.1137, blue: 0.1373)
    /// #2B2B33
    public static let border = Color(red: 0.1686, green: 0.1686, blue: 0.2000)
    /// #3A3A45
    public static let borderStrong = Color(red: 0.2275, green: 0.2275, blue: 0.2706)
    /// #ECECEF
    public static let text = Color(red: 0.9255, green: 0.9255, blue: 0.9373)
    /// #9C9CA6
    public static let textMuted = Color(red: 0.6118, green: 0.6118, blue: 0.6510)
    /// #6E6E7A
    public static let textFaint = Color(red: 0.4314, green: 0.4314, blue: 0.4784)
    /// #F0997B
    public static let accent = Color(red: 0.9412, green: 0.6000, blue: 0.4824)
    /// #F7B097
    public static let accentHover = Color(red: 0.9686, green: 0.6902, blue: 0.5922)
    /// #E0876A
    public static let accentPress = Color(red: 0.8784, green: 0.5294, blue: 0.4157)
    /// #2A1710
    public static let accentInk = Color(red: 0.1647, green: 0.0902, blue: 0.0627)
    /// #4ADE80
    public static let live = Color(red: 0.2902, green: 0.8706, blue: 0.5020)
    /// #FBBF24
    public static let warn = Color(red: 0.9843, green: 0.7490, blue: 0.1412)
    /// #F87171
    public static let error = Color(red: 0.9725, green: 0.4431, blue: 0.4431)
}

public enum DSRadius {
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 10
    public static let lg: CGFloat = 14
}

/// The spacing scale. Indexed rather than named, because naming steps invites
/// off-scale values with plausible names.
public enum DSSpacing {
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 24
    public static let s6: CGFloat = 32
}

public enum DSFont {
    public static let f1: CGFloat = 11
    public static let f2: CGFloat = 12
    public static let f3: CGFloat = 13
    public static let f4: CGFloat = 15
    public static let f5: CGFloat = 17
    public static let f6: CGFloat = 20
}
