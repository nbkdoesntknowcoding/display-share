import CoreGraphics
import XCTest

@testable import DisplayShareCore

/// Relative pointer roaming. The failure that matters here is a cursor pushed
/// into coordinates no display occupies, where macOS parks it invisibly and the
/// user has simply lost their pointer.
final class RelativePointerTests: XCTestCase {

    /// Mirrors InputInjector.moveCursorRelative's clamping.
    private func clamp(_ current: CGPoint, dx: Double, dy: Double, desktop: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(current.x + dx, desktop.minX), desktop.maxX - 1),
            y: min(max(current.y + dy, desktop.minY), desktop.maxY - 1))
    }

    /// The real arrangement here: virtual display LEFT of the main one, so the
    /// desktop spans negative x.
    private let desktop = CGRect(x: -1920, y: 0, width: 1920 + 2560, height: 1080)

    func testMovesFreelyInsideTheDesktop() {
        let p = clamp(CGPoint(x: 100, y: 500), dx: 50, dy: -20, desktop: desktop)
        XCTAssertEqual(p, CGPoint(x: 150, y: 480))
    }

    /// Crossing from the virtual display onto the main one is the whole point.
    func testCrossesTheBoundaryBetweenDisplays() {
        let p = clamp(CGPoint(x: -20, y: 400), dx: 100, dy: 0, desktop: desktop)
        XCTAssertEqual(p.x, 80, "should pass x=0 onto the main display")
    }

    func testCannotBePushedOffTheLeftEdge() {
        let p = clamp(CGPoint(x: -1900, y: 500), dx: -500, dy: 0, desktop: desktop)
        XCTAssertEqual(p.x, -1920, "clamped to the leftmost real pixel")
    }

    func testCannotBePushedOffTheRightEdge() {
        let p = clamp(CGPoint(x: 2500, y: 500), dx: 500, dy: 0, desktop: desktop)
        XCTAssertEqual(p.x, desktop.maxX - 1, "clamped to the last addressable pixel")
        XCTAssertLessThan(p.x, desktop.maxX, "maxX itself belongs to no display")
    }

    func testCannotBePushedOffVertically() {
        XCTAssertEqual(clamp(CGPoint(x: 0, y: 10), dx: 0, dy: -900, desktop: desktop).y, 0)
        XCTAssertEqual(
            clamp(CGPoint(x: 0, y: 1000), dx: 0, dy: 900, desktop: desktop).y, desktop.maxY - 1)
    }

    /// A huge delta from a stuck trackpad must still land somewhere real.
    func testAbsurdDeltasStayOnTheDesktop() {
        for (dx, dy) in [(1e6, 1e6), (-1e6, -1e6), (1e9, 0), (0, -1e9)] {
            let p = clamp(CGPoint(x: 0, y: 500), dx: dx, dy: dy, desktop: desktop)
            XCTAssertTrue(
                p.x >= desktop.minX && p.x < desktop.maxX && p.y >= desktop.minY && p.y < desktop.maxY,
                "delta (\(dx), \(dy)) escaped the desktop at \(p)")
        }
    }

    /// The receiver only gets control back when the cursor is genuinely inside
    /// the second screen, or the pointer lock would release at the wrong moment.
    func testReturnIsDetectedOnlyInsideTheVirtualDisplay() {
        let virtualBounds = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(virtualBounds.contains(CGPoint(x: -960, y: 540)))
        XCTAssertFalse(virtualBounds.contains(CGPoint(x: 100, y: 540)), "on the main display")
        XCTAssertFalse(virtualBounds.contains(CGPoint(x: 0, y: 540)), "x=0 is the main display")
    }
}
