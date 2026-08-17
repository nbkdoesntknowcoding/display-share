import CoreVideo
import XCTest

@testable import DisplayShareCore

/// Task 1.2 acceptance: the drop policy must be documented AND enforced.
final class FrameQueueTests: XCTestCase {

    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    func testDeliversInOrderWhenConsumerKeepsUp() {
        let queue = FrameQueue(capacity: 4)
        let a = makePixelBuffer()
        let b = makePixelBuffer()
        XCTAssertFalse(queue.enqueue(a))
        XCTAssertFalse(queue.enqueue(b))

        XCTAssertTrue(queue.dequeue(timeout: 0.1) === a)
        XCTAssertTrue(queue.dequeue(timeout: 0.1) === b)
        XCTAssertEqual(queue.statistics.droppedOldest, 0)
        XCTAssertEqual(queue.statistics.delivered, 2)
    }

    /// The core guarantee: under back-pressure the queue discards the OLDEST
    /// frame, never the newest. A stale frame is worthless once a newer one
    /// exists, and keeping it would show the user the past.
    func testDropsOldestNotNewestWhenFull() {
        let queue = FrameQueue(capacity: 2)
        let first = makePixelBuffer()
        let second = makePixelBuffer()
        let third = makePixelBuffer()

        XCTAssertFalse(queue.enqueue(first))
        XCTAssertFalse(queue.enqueue(second))
        XCTAssertTrue(queue.enqueue(third), "enqueue into a full queue should report a drop")

        // `first` is gone; the two most recent frames survive, in order.
        XCTAssertTrue(queue.dequeue(timeout: 0.1) === second)
        XCTAssertTrue(queue.dequeue(timeout: 0.1) === third)
        XCTAssertEqual(queue.statistics.droppedOldest, 1)
    }

    func testProducerIsNeverBlockedByASlowConsumer() {
        let queue = FrameQueue(capacity: 2)
        // Far more frames than capacity, with no consumer at all.
        let start = Date()
        for _ in 0..<1000 {
            queue.enqueue(makePixelBuffer())
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "enqueue must never block the capture thread")
        XCTAssertEqual(queue.statistics.enqueued, 1000)
        XCTAssertEqual(queue.statistics.droppedOldest, 998)
        XCTAssertEqual(queue.statistics.currentDepth, 2)
    }

    func testDepthNeverExceedsCapacity() {
        let queue = FrameQueue(capacity: 3)
        for _ in 0..<50 { queue.enqueue(makePixelBuffer()) }
        XCTAssertEqual(queue.statistics.currentDepth, 3)
        XCTAssertLessThanOrEqual(queue.statistics.highWaterMark, 3)
    }

    func testDequeueTimesOutRatherThanHanging() {
        let queue = FrameQueue(capacity: 2)
        let start = Date()
        XCTAssertNil(queue.dequeue(timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testCloseWakesAWaitingConsumer() {
        let queue = FrameQueue(capacity: 2)
        let expectation = expectation(description: "consumer returns")
        DispatchQueue.global().async {
            _ = queue.dequeue(timeout: 5.0)
            expectation.fulfill()
        }
        // Give the consumer a moment to start waiting, then close.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { queue.close() }
        wait(for: [expectation], timeout: 2.0)
    }

    func testConcurrentProducerAndConsumerStayConsistent() {
        let queue = FrameQueue(capacity: 4)
        let done = expectation(description: "producer finished")

        DispatchQueue.global().async {
            for _ in 0..<2000 { queue.enqueue(self.makePixelBuffer()) }
            done.fulfill()
        }
        var consumed = 0
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && consumed < 100 {
            if queue.dequeue(timeout: 0.05) != nil { consumed += 1 }
        }
        wait(for: [done], timeout: 5.0)

        let stats = queue.statistics
        XCTAssertEqual(stats.enqueued, 2000)
        // Nothing is invented or lost: every frame was delivered, dropped, or is still queued.
        XCTAssertEqual(stats.delivered + stats.droppedOldest + stats.currentDepth, stats.enqueued)
    }
}
