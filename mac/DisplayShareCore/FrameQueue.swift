import CoreVideo
import Foundation

/// Bounded frame buffer with an explicit **drop-oldest** policy.
///
/// DROP POLICY (Task 1.2 acceptance):
/// The queue holds at most `capacity` frames. When a producer enqueues into a
/// full queue, the OLDEST frame is discarded to make room — never the newest,
/// and the producer is never blocked.
///
/// Dropping oldest rather than newest is the whole point for a live display:
/// a stale frame has no value once a newer one exists, and blocking the
/// producer would stall ScreenCaptureKit's callback. Phase 0 measured exactly
/// that failure mode — doing real work inside the capture callback cut
/// throughput from 57.8fps to 22.8fps (docs/phase0-findings.md).
///
/// Latency is the product, so the queue is deliberately shallow: a deep queue
/// converts a slow consumer into accumulating lag instead of visible frame loss.
public final class FrameQueue: @unchecked Sendable {

    public struct Statistics: Sendable, Equatable {
        public var enqueued: Int = 0
        public var delivered: Int = 0
        /// Frames discarded because the consumer could not keep up.
        public var droppedOldest: Int = 0
        public var currentDepth: Int = 0
        public var highWaterMark: Int = 0

        public var dropRate: Double {
            enqueued > 0 ? Double(droppedOldest) / Double(enqueued) : 0
        }
    }

    private let capacity: Int
    private var buffer: [CVPixelBuffer] = []
    private let lock = NSCondition()
    private var stats = Statistics()
    private var closed = false

    public init(capacity: Int = 2) {
        precondition(capacity > 0, "FrameQueue needs room for at least one frame")
        self.capacity = capacity
    }

    /// Non-blocking. Returns true if a frame had to be dropped to make room.
    @discardableResult
    public func enqueue(_ frame: CVPixelBuffer) -> Bool {
        lock.lock()
        defer {
            lock.signal()
            lock.unlock()
        }
        guard !closed else { return false }

        var dropped = false
        while buffer.count >= capacity {
            buffer.removeFirst()
            stats.droppedOldest += 1
            dropped = true
        }
        buffer.append(frame)
        stats.enqueued += 1
        stats.currentDepth = buffer.count
        stats.highWaterMark = max(stats.highWaterMark, buffer.count)
        return dropped
    }

    /// Blocks until a frame is available, the timeout elapses, or the queue closes.
    public func dequeue(timeout: TimeInterval = 1.0) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.isEmpty && !closed {
            if !lock.wait(until: deadline) { return nil }
        }
        guard !buffer.isEmpty else { return nil }
        let frame = buffer.removeFirst()
        stats.delivered += 1
        stats.currentDepth = buffer.count
        return frame
    }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Wakes any waiting consumer so it can exit rather than hang on shutdown.
    public func close() {
        lock.lock()
        closed = true
        buffer.removeAll()
        stats.currentDepth = 0
        lock.broadcast()
        lock.unlock()
    }
}
