import Foundation

/// Wire protocol between the DisplayShare app and the `vd_helper` subprocess.
///
/// Newline-delimited JSON over a Unix domain socket. Chosen over XPC because a
/// socket survives the app process entirely: the helper keeps listening after
/// the app dies, which is what lets a crashed app re-attach to a still-live
/// virtual display instead of scattering the user's windows.
///
/// Versioned from day one — the helper ships inside the app bundle, but a stale
/// helper can still be running from a previous launch during an update.
public enum HelperProtocolVersion {
    public static let current = 1
}

/// Geometry for a virtual display. Mirrors what CGVirtualDisplay needs.
public struct DisplayConfiguration: Codable, Equatable, Sendable {
    public var name: String
    /// Logical (point) size. With hiDPI the pixel framebuffer is 2x this.
    public var width: UInt32
    public var height: UInt32
    public var refreshRate: Double
    public var hiDPI: Bool
    /// Panel diagonal, used to derive sizeInMillimeters — macOS infers DPI from
    /// physical size, which decides whether HiDPI modes are offered at all.
    public var diagonalInches: Double

    public init(
        name: String = "Display Share",
        width: UInt32 = 1920,
        height: UInt32 = 1080,
        refreshRate: Double = 60,
        hiDPI: Bool = false,
        diagonalInches: Double = 15.6
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
        self.diagonalInches = diagonalInches
    }
}

public struct HelperRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        /// Create the display, or return the existing one if geometry matches.
        case createDisplay
        /// Change mode on the LIVE display without destroying it, so windows stay put.
        case applyMode
        /// Tear down the display and exit immediately. Used on clean quit.
        case shutdown
        /// Liveness probe; also returns current state so a re-attaching app can resync.
        case status
    }

    public var id: Int
    public var command: Command
    public var configuration: DisplayConfiguration?

    public init(id: Int, command: Command, configuration: DisplayConfiguration? = nil) {
        self.id = id
        self.command = command
        self.configuration = configuration
    }
}

public struct HelperResponse: Codable, Sendable {
    /// Unsolicited notifications carry no request id.
    public enum Event: String, Codable, Sendable {
        /// Helper is listening and ready for commands.
        case ready
        /// CoreGraphics tore the display down on its own (terminationHandler).
        case displayTerminated
    }

    public var id: Int?
    public var ok: Bool
    public var event: Event?
    public var protocolVersion: Int?
    public var displayID: UInt32?
    public var configuration: DisplayConfiguration?
    /// Geometry macOS actually adopted, which can differ from what was asked.
    public var actualWidth: UInt32?
    public var actualHeight: UInt32?
    public var message: String?

    public init(
        id: Int? = nil,
        ok: Bool,
        event: Event? = nil,
        protocolVersion: Int? = nil,
        displayID: UInt32? = nil,
        configuration: DisplayConfiguration? = nil,
        actualWidth: UInt32? = nil,
        actualHeight: UInt32? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.ok = ok
        self.event = event
        self.protocolVersion = protocolVersion
        self.displayID = displayID
        self.configuration = configuration
        self.actualWidth = actualWidth
        self.actualHeight = actualHeight
        self.message = message
    }
}

public enum HelperPaths {
    /// Socket lives under Application Support rather than /tmp so it is
    /// per-user and not world-writable. Unix socket paths are capped near 104
    /// bytes; this stays well inside that.
    public static var socketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("DisplayShare", isDirectory: true)
            .appendingPathComponent("vd_helper.sock")
    }

    public static func ensureParentDirectory() throws {
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
