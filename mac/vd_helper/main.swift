// Display Share — use a Windows laptop as a second display for a Mac.
// Copyright (C) 2026 Nischay B K
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version. See the LICENSE file at the repository root.

import CoreGraphics
import Darwin
import Foundation

// vd_helper — holds the CGVirtualDisplay alive, isolated from the app.
//
// Lifecycle contract (Task 1.1 acceptance):
//   • clean `shutdown` command  -> display removed immediately, helper exits
//   • app disconnects unexpectedly (crash / SIGKILL) -> the display is KEPT for
//     a grace period so a relaunching app can re-attach without the user's
//     windows being scattered; if nobody re-attaches, the helper exits and the
//     display goes away. That is what reconciles "a crash must not tear down
//     the helper" with "force-kill must not leave an orphaned display".

setvbuf(stdout, nil, _IONBF, 0)

func log(_ message: String) {
    FileHandle.standardError.write("[vd_helper] \(message)\n".data(using: .utf8)!)
}

// --- arguments ----------------------------------------------------------
var socketPath = HelperPaths.socketURL.path
var graceSeconds: Double = 8.0
do {
    var argv = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--socket" where i + 1 < argv.count:
            socketPath = argv[i + 1]
            i += 2
        case "--grace" where i + 1 < argv.count:
            graceSeconds = Double(argv[i + 1]) ?? graceSeconds
            i += 2
        default:
            i += 1
        }
    }
}

// --- state --------------------------------------------------------------
final class HelperState: @unchecked Sendable {
    let host = VirtualDisplayHost()
    let lock = NSLock()
    var connection: LineConnection?
    /// Cancelled when a new client attaches inside the grace window.
    var graceWorkItem: DispatchWorkItem?
    /// Held so teardown can stop accepting before the display goes away.
    var server: LineSocketServer?
}

let state = HelperState()

func respond(_ response: HelperResponse) {
    state.lock.lock()
    let conn = state.connection
    state.lock.unlock()
    _ = conn?.send(response)
}

func teardownAndExit(_ code: Int32, reason: String) -> Never {
    log("shutting down: \(reason)")
    // Stop listening BEFORE tearing the display down. Otherwise a relaunching
    // app can connect to a helper that is already dying, create a display on
    // it, and lose that display moments later when this process exits.
    // Unlinking the socket path also frees it for the next helper to bind.
    state.server?.stop()
    state.host.stop()
    // Give CoreGraphics a moment to actually retire the display before the
    // process image goes away.
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    exit(code)
}

func handle(_ request: HelperRequest) {
    switch request.command {
    case .status:
        respond(
            HelperResponse(
                id: request.id, ok: true,
                protocolVersion: HelperProtocolVersion.current,
                displayID: state.host.isActive ? state.host.displayID : nil,
                configuration: state.host.configuration))

    case .createDisplay:
        guard let config = request.configuration else {
            respond(HelperResponse(id: request.id, ok: false, message: "createDisplay requires a configuration"))
            return
        }
        // Already running with identical geometry: return it rather than
        // recreating, so a re-attaching app keeps the user's windows in place.
        if state.host.isActive, state.host.configuration == config {
            log("re-using existing display 0x\(String(state.host.displayID, radix: 16))")
            respond(
                HelperResponse(
                    id: request.id, ok: true, displayID: state.host.displayID,
                    configuration: state.host.configuration))
            return
        }
        // Live geometry change: apply to the existing display, still no destroy.
        if state.host.isActive {
            if state.host.applyMode(config) {
                log("applied new mode to existing display")
                respond(
                    HelperResponse(
                        id: request.id, ok: true, displayID: state.host.displayID,
                        configuration: state.host.configuration))
                return
            }
            state.host.stop()
        }
        do {
            let id = try state.host.start(config) {
                log("CoreGraphics terminated the display")
                respond(HelperResponse(ok: true, event: .displayTerminated))
            }
            log("created display 0x\(String(id, radix: 16)) \(config.width)x\(config.height)")
            respond(
                HelperResponse(
                    id: request.id, ok: true, displayID: id, configuration: state.host.configuration))
        } catch {
            log("create failed: \(error)")
            respond(HelperResponse(id: request.id, ok: false, message: "\(error)"))
        }

    case .applyMode:
        guard let config = request.configuration else {
            respond(HelperResponse(id: request.id, ok: false, message: "applyMode requires a configuration"))
            return
        }
        guard state.host.isActive else {
            respond(HelperResponse(id: request.id, ok: false, message: "no display is active"))
            return
        }
        let ok = state.host.applyMode(config)
        // Poll briefly: the window server adopts the new mode asynchronously.
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if let actual = state.host.actualSize, actual.width == config.width { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let actual = state.host.actualSize
        if let actual, actual.width != config.width || actual.height != config.height {
            log("requested \(config.width)x\(config.height) but macOS adopted \(actual.width)x\(actual.height)")
        }
        respond(
            HelperResponse(
                id: request.id, ok: ok, displayID: state.host.displayID,
                configuration: state.host.configuration,
                actualWidth: actual?.width, actualHeight: actual?.height,
                message: ok ? nil : "CoreGraphics rejected the mode"))

    case .shutdown:
        respond(HelperResponse(id: request.id, ok: true))
        DispatchQueue.main.async {
            teardownAndExit(0, reason: "shutdown requested by app")
        }
    }
}

// --- socket server ------------------------------------------------------
do {
    try HelperPaths.ensureParentDirectory()
} catch {
    log("could not create socket directory: \(error)")
}

let server = LineSocketServer(path: socketPath)
state.server = server
do {
    try server.start()
} catch {
    log("failed to listen on \(socketPath): \(error)")
    exit(1)
}
log("listening on \(socketPath)")

// Accept loop on its own thread; blocking accept()/read() must not sit on the
// run loop the display machinery needs.
let acceptThread = Thread {
    while true {
        guard let conn = server.accept() else {
            Thread.sleep(forTimeInterval: 0.1)
            continue
        }
        state.lock.lock()
        // A re-attach inside the grace window cancels the pending teardown.
        state.graceWorkItem?.cancel()
        state.graceWorkItem = nil
        state.connection?.close()
        state.connection = conn
        state.lock.unlock()
        log("app attached")

        _ = conn.send(
            HelperResponse(ok: true, event: .ready, protocolVersion: HelperProtocolVersion.current))

        while let line = conn.readLine() {
            guard let request = try? JSONDecoder().decode(HelperRequest.self, from: line) else {
                log("undecodable request: \(String(data: line, encoding: .utf8) ?? "<binary>")")
                continue
            }
            DispatchQueue.main.async { handle(request) }
        }

        // EOF: the app went away without saying goodbye.
        log("app detached unexpectedly")
        state.lock.lock()
        if state.connection === conn { state.connection = nil }
        conn.close()

        let work = DispatchWorkItem {
            teardownAndExit(0, reason: "no app re-attached within \(graceSeconds)s grace period")
        }
        state.graceWorkItem = work
        state.lock.unlock()
        log("holding display for \(graceSeconds)s in case the app comes back")
        DispatchQueue.main.asyncAfter(deadline: .now() + graceSeconds, execute: work)
    }
}
acceptThread.name = "vd_helper.accept"
acceptThread.start()

// Terminate cleanly on signals so the display never outlives the process.
// Sources must be retained or they are cancelled on deinit.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { teardownAndExit(0, reason: "signal \(sig)") }
    src.resume()
    signalSources.append(src)
}

// A bare executable must run a real run loop: CoreGraphics only refreshes this
// process's view of the display configuration when reconfiguration
// notifications are serviced. See docs/phase0-findings.md.
CFRunLoopRun()
