import Foundation

/// App-side control channel to `vd_helper`.
///
/// Connect-first, spawn-only-if-needed. That ordering is what makes crash
/// recovery work: after the app dies and relaunches, a helper from the previous
/// session may still be holding the display inside its grace window, and
/// re-attaching to it preserves the user's window arrangement.
public final class HelperClient: @unchecked Sendable {

    public enum ClientError: Error, CustomStringConvertible {
        case helperBinaryMissing(String)
        case couldNotConnect(String)
        case helperRejected(String)
        case timedOut(String)

        public var description: String {
            switch self {
            case .helperBinaryMissing(let p): return "vd_helper not found at \(p)"
            case .couldNotConnect(let s): return "could not connect to vd_helper: \(s)"
            case .helperRejected(let s): return "vd_helper rejected the request: \(s)"
            case .timedOut(let s): return "timed out waiting for \(s)"
            }
        }
    }

    private let socketPath: String
    private let helperURL: URL
    private var connection: LineConnection?
    private var readerThread: Thread?
    private var spawned: Process?

    private let lock = NSLock()
    private var nextRequestID = 1
    private var pending: [Int: (HelperResponse) -> Void] = [:]

    /// Fired when CoreGraphics tears the display down on its own.
    public var onDisplayTerminated: (() -> Void)?
    /// Fired when the helper connection drops.
    public var onDisconnected: (() -> Void)?

    public private(set) var protocolVersion: Int?

    public init(socketPath: String = HelperPaths.socketURL.path, helperURL: URL? = nil) {
        self.socketPath = socketPath
        self.helperURL = helperURL ?? Self.defaultHelperURL()
    }

    /// The helper is copied into Contents/MacOS alongside the app executable.
    /// DS_HELPER_PATH overrides it for command-line testing outside a bundle.
    public static func defaultHelperURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["DS_HELPER_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let exec = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exec.deletingLastPathComponent().appendingPathComponent("vd_helper")
    }

    // MARK: - Connection

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connection != nil
    }

    /// Attaches to a running helper, spawning one only if none answers.
    public func connect(timeout: TimeInterval = 5.0) throws {
        if isConnected { return }

        if let conn = try? LineSocketClient.connect(path: socketPath) {
            adopt(conn)
            return
        }

        try spawnHelper()

        // The helper needs a moment to bind its socket.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let conn = try? LineSocketClient.connect(path: socketPath) {
                adopt(conn)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ClientError.timedOut("vd_helper to start listening")
    }

    private func spawnHelper() throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ClientError.helperBinaryMissing(helperURL.path)
        }
        try? HelperPaths.ensureParentDirectory()

        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--socket", socketPath]
        // Inherit stderr so helper logs land in the app's log stream.
        try process.run()
        spawned = process
    }

    private func adopt(_ conn: LineConnection) {
        lock.lock()
        connection = conn
        lock.unlock()

        let thread = Thread { [weak self] in
            while let line = conn.readLine() {
                guard let response = try? JSONDecoder().decode(HelperResponse.self, from: line) else { continue }
                self?.dispatch(response)
            }
            self?.handleDisconnect(conn)
        }
        thread.name = "HelperClient.reader"
        thread.start()
        readerThread = thread
    }

    private func dispatch(_ response: HelperResponse) {
        if let event = response.event {
            switch event {
            case .ready:
                protocolVersion = response.protocolVersion
            case .displayTerminated:
                onDisplayTerminated?()
            }
            if response.id == nil { return }
        }
        guard let id = response.id else { return }
        lock.lock()
        let handler = pending.removeValue(forKey: id)
        lock.unlock()
        handler?(response)
    }

    private func handleDisconnect(_ conn: LineConnection) {
        lock.lock()
        if connection === conn { connection = nil }
        let handlers = pending
        pending.removeAll()
        lock.unlock()
        // Fail rather than hang anything still waiting on a reply.
        for (_, handler) in handlers {
            handler(HelperResponse(ok: false, message: "helper disconnected"))
        }
        onDisconnected?()
    }

    // MARK: - Requests

    @discardableResult
    private func send(_ command: HelperRequest.Command, configuration: DisplayConfiguration? = nil, timeout: TimeInterval = 10)
        throws -> HelperResponse
    {
        lock.lock()
        guard let conn = connection else {
            lock.unlock()
            throw ClientError.couldNotConnect("not connected")
        }
        let id = nextRequestID
        nextRequestID += 1
        let semaphore = DispatchSemaphore(value: 0)
        var result: HelperResponse?
        pending[id] = { response in
            result = response
            semaphore.signal()
        }
        lock.unlock()

        guard conn.send(HelperRequest(id: id, command: command, configuration: configuration)) else {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            throw ClientError.couldNotConnect("write failed")
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success, let response = result else {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            throw ClientError.timedOut("\(command.rawValue) response")
        }
        guard response.ok else {
            throw ClientError.helperRejected(response.message ?? "unknown error")
        }
        return response
    }

    /// Creates the display, or adopts an identical one already held by a helper
    /// that survived an app crash.
    @discardableResult
    public func createDisplay(_ configuration: DisplayConfiguration) throws -> UInt32 {
        let response = try send(.createDisplay, configuration: configuration)
        guard let displayID = response.displayID else {
            throw ClientError.helperRejected("helper returned no displayID")
        }
        return displayID
    }

    @discardableResult
    public func applyMode(_ configuration: DisplayConfiguration) throws -> UInt32 {
        let response = try send(.applyMode, configuration: configuration)
        guard let displayID = response.displayID else {
            throw ClientError.helperRejected("helper returned no displayID")
        }
        return displayID
    }

    public func status() throws -> HelperResponse {
        try send(.status)
    }

    /// Clean teardown: the display goes away immediately, no grace period.
    public func shutdown(timeout: TimeInterval = 3.0) {
        if isConnected {
            _ = try? send(.shutdown, timeout: timeout)
        }
        lock.lock()
        connection?.close()
        connection = nil
        lock.unlock()

        // Belt and braces: if the helper we spawned is somehow still alive,
        // do not leave it holding a display.
        if let process = spawned, process.isRunning {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { process.terminate() }
        }
        spawned = nil
    }
}
