// Draws the DMG window background (Task 9.3).
//
// The instructions live in the BACKGROUND rather than in a text file beside the
// app, because a second icon in the window competes with the drag gesture and
// most people never open it. Both operating systems warn on first launch for an
// unsigned build, so the exact click path is stated here — before the scary
// dialog appears, not after.
//
//   swift make-dmg-background.swift <output.png> [version]

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <out.png> [version]\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let version = arguments.count > 2 ? arguments[2] : ""

// 1x layout is 640x400 to match create-dmg's --window-size; drawn at 2x so the
// text is not soft on a Retina display.
let scale: CGFloat = 2
let size = CGSize(width: 640, height: 400)

guard
    let context = CGContext(
        data: nil,
        width: Int(size.width * scale),
        height: Int(size.height * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    FileHandle.standardError.write(Data("could not create a bitmap context\n".utf8))
    exit(1)
}
context.scaleBy(x: scale, y: scale)

let graphics = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = graphics

// Background: near-black with a cool wash behind the title, matching the apps.
context.setFillColor(NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.055, alpha: 1).cgColor)
context.fill(CGRect(origin: .zero, size: size))
if let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 0.20).cgColor,
        NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 0.0).cgColor,
    ] as CFArray,
    locations: [0, 1]
) {
    context.drawRadialGradient(
        gradient,
        startCenter: CGPoint(x: size.width / 2, y: size.height + 40), startRadius: 0,
        endCenter: CGPoint(x: size.width / 2, y: size.height + 40), endRadius: 420,
        options: []
    )
}

func draw(
    _ text: String, at point: CGPoint, size fontSize: CGFloat, weight: NSFont.Weight = .regular,
    colour: NSColor, width: CGFloat, alignment: NSTextAlignment = .left
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineSpacing = 2.5
    let attributed = NSAttributedString(
        string: text,
        attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: colour,
            .paragraphStyle: paragraph,
        ]
    )
    // y is measured from the bottom in this context, so the caller passes the
    // TOP of the box and it is converted here.
    let bounding = attributed.boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    // Padded: boundingRect under-reports a wrapped paragraph's height, and
    // draw(with:) CLIPS to the rect it is given — which silently cut the last
    // line of the warning in half.
    let height = ceil(bounding.height) + 8
    attributed.draw(
        with: CGRect(x: point.x, y: point.y - height, width: width, height: height),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
}

let white = NSColor(calibratedWhite: 0.96, alpha: 1)
let muted = NSColor(calibratedWhite: 0.62, alpha: 1)
let warn = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.35, alpha: 1)

draw(
    version.isEmpty ? "Display Share" : "Display Share \(version)",
    at: CGPoint(x: 36, y: size.height - 30), size: 22, weight: .semibold, colour: white, width: 420
)
draw(
    "Drag the app onto Applications to install.",
    at: CGPoint(x: 36, y: size.height - 62), size: 12.5, colour: muted, width: 420
)

// The arrow sits between the two icon positions create-dmg is told to use
// (160,180) and (480,180), so it reads as one gesture.
let arrowY = size.height - 180
context.setStrokeColor(NSColor(calibratedWhite: 0.45, alpha: 1).cgColor)
context.setLineWidth(2)
context.setLineDash(phase: 0, lengths: [7, 6])
context.move(to: CGPoint(x: 250, y: arrowY))
context.addLine(to: CGPoint(x: 386, y: arrowY))
context.strokePath()
context.setLineDash(phase: 0, lengths: [])
context.setFillColor(NSColor(calibratedWhite: 0.45, alpha: 1).cgColor)
context.move(to: CGPoint(x: 404, y: arrowY))
context.addLine(to: CGPoint(x: 386, y: arrowY + 8))
context.addLine(to: CGPoint(x: 386, y: arrowY - 8))
context.closePath()
context.fillPath()

// The whole point of this task: say what will happen BEFORE it happens.
draw(
    "First launch will be blocked — this build is unsigned",
    at: CGPoint(x: 36, y: 118), size: 12.5, weight: .semibold, colour: warn, width: 568
)
draw(
    """
    Display Share is open source and buys no code signing certificate, so macOS \
    will refuse the first launch. Right-click the app in Applications and choose \
    Open, then confirm. If it is still blocked, open System Settings ▸ Privacy & \
    Security and click Open Anyway.
    """,
    at: CGPoint(x: 36, y: 96), size: 11.5, colour: muted, width: 568
)

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("could not render the image\n".utf8))
    exit(1)
}
let bitmap = NSBitmapImageRep(cgImage: image)
bitmap.size = size
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode PNG\n".utf8))
    exit(1)
}
try data.write(to: output)
