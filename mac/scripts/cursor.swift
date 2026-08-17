// Reads or restores the cursor position, for the Task 5.2 injection test.
import CoreGraphics
import Foundation
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "set", args.count == 3, let x = Double(args[1]), let y = Double(args[2]) {
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
} else {
    let p = CGEvent(source: nil)?.location ?? .zero
    print("\(p.x) \(p.y)")
}
