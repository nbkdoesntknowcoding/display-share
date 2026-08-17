import Combine
import Foundation

/// Observable façade the SwiftUI menu bar drives.
///
/// Owns the helper lifecycle and keeps the UI honest about what is actually
/// running — including the case where the app re-attached to a display that
/// outlived a previous crash.
@MainActor
public final class DisplayShareController: ObservableObject {

    public enum State: Equatable {
        case idle
        case starting
        case active(displayID: UInt32)
        case failed(String)

        public var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var configuration = DisplayConfiguration()
    /// True when we adopted a display held by a helper that survived a crash.
    @Published public private(set) var reattached = false

    private let client: HelperClient

    public init(client: HelperClient = HelperClient()) {
        self.client = client
        self.client.onDisplayTerminated = { [weak self] in
            Task { @MainActor in self?.state = .failed("macOS removed the display") }
        }
        self.client.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.state.isActive else { return }
                self.state = .failed("Lost connection to vd_helper")
            }
        }
    }

    public func start() {
        guard !state.isActive else { return }
        state = .starting
        do {
            try client.connect()
            // If a helper is already holding our display, this is a re-attach.
            let existing = try? client.status()
            let hadDisplay = existing?.displayID != nil
            let displayID = try client.createDisplay(configuration)
            reattached = hadDisplay
            state = .active(displayID: displayID)
        } catch {
            state = .failed("\(error)")
        }
    }

    public func stop() {
        client.shutdown()
        reattached = false
        state = .idle
    }

    /// Live resolution change — applied to the existing display so the user's
    /// windows are not scattered.
    public func update(configuration new: DisplayConfiguration) {
        configuration = new
        guard state.isActive else { return }
        do {
            let displayID = try client.applyMode(new)
            state = .active(displayID: displayID)
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Called from applicationWillTerminate so a clean quit never leaves a display.
    public func shutdownForQuit() {
        client.shutdown()
    }
}
