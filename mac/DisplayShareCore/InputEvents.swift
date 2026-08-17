import Foundation

/// Validates a batch and tracks ordering, so out-of-order or malformed input is
/// rejected at the boundary rather than reaching CGEvent.
public final class InputEventSink: @unchecked Sendable {

    public struct Statistics: Sendable, Equatable {
        public var batches = 0
        public var accepted = 0
        /// Events whose `t` went backwards relative to the previous event.
        public var outOfOrder = 0
        /// Coordinates outside 0-1, which the receiver should never send.
        public var outOfRange = 0
        public var lastTimestamp = 0
        public var moves = 0
        public var buttons = 0
        public var scrolls = 0
        public var keys = 0
    }

    private let lock = NSLock()
    private var stats = Statistics()
    private var logging = false

    /// Called for each accepted event, in order. Task 5.2 attaches the injector.
    public var onEvent: ((ForwardedInputEvent) -> Void)?

    public init(logging: Bool = false) {
        self.logging = logging
    }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    public func setLogging(_ enabled: Bool) {
        lock.lock(); logging = enabled; lock.unlock()
    }

    /// Decodes and dispatches one `input` batch.
    public func ingest(_ events: [ForwardedInputEvent]) {
        lock.lock()
        stats.batches += 1
        var shouldLog = logging
        lock.unlock()

        for event in events {
            lock.lock()
            // Ordering is a correctness property: replaying a move after a later
            // one would visibly jump the cursor backwards.
            if event.t < stats.lastTimestamp {
                stats.outOfOrder += 1
                lock.unlock()
                if shouldLog { log("DROP out-of-order t=\(event.t) < \(stats.lastTimestamp)") }
                continue
            }
            stats.lastTimestamp = event.t

            if event.k == .move {
                guard let x = event.x, let y = event.y,
                    x >= 0, x <= 1, y >= 0, y <= 1
                else {
                    stats.outOfRange += 1
                    lock.unlock()
                    if shouldLog { log("DROP out-of-range move x=\(event.x ?? -1) y=\(event.y ?? -1)") }
                    continue
                }
                stats.moves += 1
            }
            switch event.k {
            case .down, .up: stats.buttons += 1
            case .scroll: stats.scrolls += 1
            case .key: stats.keys += 1
            case .move: break
            }
            stats.accepted += 1
            shouldLog = logging
            lock.unlock()

            if shouldLog { log(describe(event)) }
            onEvent?(event)
        }
    }

    private func describe(_ event: ForwardedInputEvent) -> String {
        switch event.k {
        case .move:
            return String(format: "move  x=%.4f y=%.4f t=%d", event.x ?? 0, event.y ?? 0, event.t)
        case .down, .up:
            return "\(event.k == .down ? "down" : "up")  button=\(event.b ?? -1) t=\(event.t)"
        case .scroll:
            return String(format: "scroll dx=%.2f dy=%.2f t=%d", event.dx ?? 0, event.dy ?? 0, event.t)
        case .key:
            let mods = event.mods
            let flags = [
                mods?.shift == true ? "shift" : nil,
                mods?.ctrl == true ? "ctrl" : nil,
                mods?.alt == true ? "alt" : nil,
                mods?.meta == true ? "cmd" : nil,
            ].compactMap { $0 }.joined(separator: "+")
            return "key   \(event.code ?? "?") \(event.down == true ? "down" : "up")"
                + (flags.isEmpty ? "" : " [\(flags)]") + " t=\(event.t)"
        }
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data("[DisplayShare] input: \(text)\n".utf8))
    }
}
