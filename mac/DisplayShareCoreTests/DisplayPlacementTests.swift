import CoreGraphics
import XCTest

@testable import DisplayShareCore

/// Saying where the second screen went.
///
/// The bug this closes is not a crash or a wrong pixel: the app placed a
/// display, knew exactly where, and left the user pushing their cursor at the
/// wrong edge and concluding that input forwarding was broken.
final class DisplayPlacementTests: XCTestCase {

    private let main = CGRect(x: 0, y: 0, width: 2560, height: 1080)

    /// What macOS actually does with a virtual display, and the case that was
    /// reported: it lands on the left, and pushing right does nothing.
    func testTheDefaultPlacementIsRecognisedAsLeft() {
        let virtual = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(DisplayPlacement.of(virtual, relativeTo: main), .left)
    }

    func testAScreenPlacedToTheRight() {
        XCTAssertEqual(
            DisplayPlacement.of(
                CGRect(x: 2560, y: 0, width: 1920, height: 1080), relativeTo: main),
            .right)
    }

    /// Cocoa's y axis points up, so a greater y is physically higher. Getting
    /// this backwards would send the reader to precisely the wrong edge.
    func testVerticalPlacementFollowsCocoaCoordinates() {
        XCTAssertEqual(
            DisplayPlacement.of(
                CGRect(x: 0, y: 1080, width: 2560, height: 1080), relativeTo: main),
            .above)
        XCTAssertEqual(
            DisplayPlacement.of(
                CGRect(x: 0, y: -1080, width: 2560, height: 1080), relativeTo: main),
            .below)
    }

    /// Offset on both axes is normal. The answer must be the edge the cursor
    /// actually crosses, which is the one it is further along.
    func testTheDominantAxisDecides() {
        // Far left, slightly high.
        let mostlyLeft = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        XCTAssertEqual(DisplayPlacement.of(mostlyLeft, relativeTo: main), .left)

        // Slightly left, far above.
        let mostlyAbove = CGRect(x: -200, y: 1400, width: 1920, height: 1080)
        XCTAssertEqual(DisplayPlacement.of(mostlyAbove, relativeTo: main), .above)
    }

    /// Every case must produce copy that names a direction, or the sentence
    /// tells the reader nothing they can act on.
    func testEveryPlacementNamesADirection() {
        for placement in DisplayPlacement.allCases {
            let text = placement.describedForUser.lowercased()
            XCTAssertTrue(
                ["left", "right", "above", "below"].contains(where: text.contains),
                "\(placement) reads as \"\(text)\", which names no direction")
        }
    }
}
