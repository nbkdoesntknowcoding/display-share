// Draws the Display Share mark (Command 2 of the UI/UX audit).
//
// Two overlapping rounded rectangles: one display extending into another, which
// is literally what the product does. Accent on near-black, both taken from
// design/tokens.json rather than restated here.
//
//   swift make-icon.swift <out.png> <size> [mono]
//
// `mono` emits a flat template image for the macOS status item. macOS tints
// template images itself for light and dark menu bars, so it must be a single
// colour with alpha — a coloured status icon is the classic mistake.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let size = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.png> <size> [mono]\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: args[1])
let mono = args.count > 3 && args[3] == "mono"

// Read the accent from the token source so the icon can never drift from the UI.
let tokensURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("tokens.json")
func hex(_ name: String, fallback: String) -> NSColor {
    guard let data = try? Data(contentsOf: tokensURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let colors = json["colors"] as? [String: String],
        let value = colors[name] ?? Optional(fallback)
    else { return .black }
    var int = UInt64()
    Scanner(string: String(value.dropFirst())).scanHexInt64(&int)
    return NSColor(
        red: CGFloat((int >> 16) & 255) / 255,
        green: CGFloat((int >> 8) & 255) / 255,
        blue: CGFloat(int & 255) / 255,
        alpha: 1
    )
}

let scale = size / 1024.0
guard
    let context = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else { exit(1) }
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
context.scaleBy(x: scale, y: scale)

let accent = hex("accent", fallback: "#F0997B")
let background = hex("bg", fallback: "#0A0A0C")

if !mono {
    // Squircle background, matching the macOS icon grid rather than a full square.
    let plate = CGPath(
        roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
        cornerWidth: 200, cornerHeight: 200, transform: nil
    )
    context.addPath(plate)
    context.setFillColor(background.cgColor)
    context.fillPath()
}

// The back display: outlined, sitting up and to the left.
let stroke = mono ? NSColor.black : accent
context.setStrokeColor(stroke.withAlphaComponent(mono ? 0.55 : 0.55).cgColor)
context.setLineWidth(46)
context.addPath(CGPath(
    roundedRect: CGRect(x: 210, y: 330, width: 430, height: 330),
    cornerWidth: 54, cornerHeight: 54, transform: nil
))
context.strokePath()

// The front display: filled, overlapping down and to the right. The overlap is
// the whole idea — one screen becoming two.
context.setFillColor(stroke.cgColor)
context.addPath(CGPath(
    roundedRect: CGRect(x: 384, y: 200, width: 430, height: 330),
    cornerWidth: 54, cornerHeight: 54, transform: nil
))
context.fillPath()

guard let image = context.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: output)
