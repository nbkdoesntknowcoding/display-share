import Darwin
import Foundation

/// Minimal newline-delimited framing over a POSIX Unix domain socket.
///
/// Deliberately POSIX rather than Network.framework: the helper is a bare
/// executable that must also run a CFRunLoop (see docs/phase0-findings.md), and
/// blocking reads on a dedicated thread are far easier to reason about than
/// interleaving NWConnection state machines with that run loop.
public enum LineSocketError: Error, CustomStringConvertible {
    case socketFailed(String)
    case pathTooLong
    case connectFailed(String)
    case bindFailed(String)
    case closed

    public var description: String {
        switch self {
        case .socketFailed(let s): return "socket() failed: \(s)"
        case .pathTooLong: return "socket path exceeds sun_path capacity"
        case .connectFailed(let s): return "connect() failed: \(s)"
        case .bindFailed(let s): return "bind()/listen() failed: \(s)"
        case .closed: return "connection closed"
        }
    }
}

private func makeSockaddr(path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else { throw LineSocketError.pathTooLong }
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
            dst[bytes.count] = 0
        }
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

/// One end of a connected socket. Reads are blocking and intended to run on a
/// dedicated thread; writes are serialised behind a lock.
public final class LineConnection: @unchecked Sendable {
    private let fd: Int32
    private var readBuffer = Data()
    private let writeLock = NSLock()
    private var closed = false

    public init(fd: Int32) {
        self.fd = fd
    }

    deinit { close() }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        closed = true
        _ = Darwin.close(fd)
    }

    /// Blocks until a full line arrives. Returns nil on EOF or error — which is
    /// how the helper learns the app went away.
    public func readLine() -> Data? {
        while true {
            if let range = readBuffer.firstRange(of: Data([0x0A])) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<range.lowerBound)
                readBuffer.removeSubrange(readBuffer.startIndex..<range.upperBound)
                if line.isEmpty { continue }
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            readBuffer.append(contentsOf: chunk[0..<n])
        }
    }

    @discardableResult
    public func write(_ payload: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return false }
        var data = payload
        data.append(0x0A)
        return data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    public func send<T: Encodable>(_ value: T) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return write(data)
    }
}

/// Listening socket. `accept()` blocks, so callers run it on their own thread.
public final class LineSocketServer {
    private let path: String
    private var listenFD: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    public func start(backlog: Int32 = 4) throws {
        // A stale socket file from a previous run would make bind() fail with
        // EADDRINUSE even though nobody is listening.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LineSocketError.socketFailed(String(cString: strerror(errno))) }

        var addr = try makeSockaddr(path: path)
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            _ = Darwin.close(fd)
            throw LineSocketError.bindFailed(String(cString: strerror(errno)))
        }
        // Owner-only: nobody else on the machine may drive our virtual display.
        chmod(path, 0o600)

        guard listen(fd, backlog) == 0 else {
            _ = Darwin.close(fd)
            throw LineSocketError.bindFailed(String(cString: strerror(errno)))
        }
        listenFD = fd
    }

    public func accept() -> LineConnection? {
        guard listenFD >= 0 else { return nil }
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return nil }
        return LineConnection(fd: client)
    }

    public func stop() {
        if listenFD >= 0 {
            _ = Darwin.close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }
}

public enum LineSocketClient {
    /// Connects to an existing helper. Failure here is the normal signal that
    /// no helper is running yet and one must be spawned.
    public static func connect(path: String) throws -> LineConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LineSocketError.socketFailed(String(cString: strerror(errno))) }
        var addr = try makeSockaddr(path: path)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            _ = Darwin.close(fd)
            throw LineSocketError.connectFailed(String(cString: strerror(errno)))
        }
        return LineConnection(fd: fd)
    }
}
