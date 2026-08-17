import Foundation
import Network

/// Minimal HTTP server serving an MJPEG stream, plus a viewer page and a stats
/// endpoint for the debug HUD.
///
///   GET /         viewer page: fullscreen <img> + HUD
///   GET /stream   multipart/x-mixed-replace MJPEG
///   GET /stats    JSON for the HUD
///
/// Phase 1 scaffolding. MJPEG costs roughly 4x the bandwidth of H.264 and adds
/// latency, but it needs zero client code — which is the point: it validates
/// display creation and capture before any codec complexity (Phase 2) is added.
public final class MJPEGServer: @unchecked Sendable {

    public struct Statistics: Sendable {
        public var connectedClients: Int = 0
        public var framesSent: Int = 0
        public var bytesSent: Int = 0
        public var captureFPS: Double = 0
        public var sentFPS: Double = 0
        public var encodeMillis: Double = 0
        public var lastFrameBytes: Int = 0
        public var droppedFrames: Int = 0
        /// Megabits per second on the wire.
        public var megabitsPerSecond: Double = 0
    }

    private let port: NWEndpoint.Port
    private let boundary = "displayshareframe"
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "in.theboringpeople.displayshare.http")

    private let lock = NSLock()
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var stats = Statistics()

    private var windowStart = CFAbsoluteTimeGetCurrent()
    private var windowFrames = 0
    private var windowBytes = 0

    public private(set) var isRunning = false

    public init(port: UInt16 = 8787) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        isRunning = true
    }

    public func stop() {
        isRunning = false
        listener?.cancel()
        listener = nil
        lock.lock()
        let current = clients.values
        clients.removeAll()
        stats.connectedClients = 0
        lock.unlock()
        for connection in current { connection.cancel() }
    }

    // MARK: - Request handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, !data.isEmpty, error == nil else {
                if isComplete || error != nil { connection.cancel() }
                return
            }
            let request = String(decoding: data, as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

            switch path {
            case "/stream":
                self.startStreaming(to: connection)
            case "/stats":
                self.sendJSON(self.statistics, on: connection)
            case "/", "/index.html":
                self.sendHTML(Self.viewerPage, on: connection)
            default:
                self.sendPlain("404 not found", status: "404 Not Found", on: connection)
            }
        }
    }

    /// Builds a complete response. Header lines are joined with CRLF and
    /// terminated by a blank line — assembled explicitly rather than via a
    /// multi-line literal, where stray CRs are easy to introduce and produce a
    /// 200 with an empty body.
    private func httpResponse(status: String, contentType: String, body: Data, extraHeaders: [String] = []) -> Data {
        var lines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store, no-cache, must-revalidate",
            "Pragma: no-cache",
            "Connection: close",
        ]
        lines.append(contentsOf: extraHeaders)
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(Data("\r\n\r\n".utf8))
        data.append(body)
        return data
    }

    private func sendHTML(_ html: String, on connection: NWConnection) {
        let response = httpResponse(
            status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendPlain(_ text: String, status: String, on connection: NWConnection) {
        let response = httpResponse(status: status, contentType: "text/plain", body: Data(text.utf8))
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendJSON(_ stats: Statistics, on connection: NWConnection) {
        let json = """
            {"clients":\(stats.connectedClients),"framesSent":\(stats.framesSent),\
            "captureFPS":\(String(format: "%.1f", stats.captureFPS)),\
            "sentFPS":\(String(format: "%.1f", stats.sentFPS)),\
            "encodeMs":\(String(format: "%.2f", stats.encodeMillis)),\
            "frameKB":\(stats.lastFrameBytes / 1024),\
            "mbps":\(String(format: "%.2f", stats.megabitsPerSecond)),\
            "dropped":\(stats.droppedFrames)}
            """
        let response = httpResponse(
            status: "200 OK", contentType: "application/json", body: Data(json.utf8))
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func startStreaming(to connection: NWConnection) {
        // No Content-Length: the body is unbounded and the connection stays open.
        let head = [
            "HTTP/1.1 200 OK",
            "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)",
            "Cache-Control: no-store, no-cache, must-revalidate",
            "Pragma: no-cache",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        let key = ObjectIdentifier(connection)
        lock.lock()
        clients[key] = connection
        stats.connectedClients = clients.count
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.remove(key)
            default:
                break
            }
        }
    }

    private func remove(_ key: ObjectIdentifier) {
        lock.lock()
        clients.removeValue(forKey: key)
        stats.connectedClients = clients.count
        lock.unlock()
    }

    /// Capture-side stats, published whether or not anyone is watching.
    public func updateCaptureStats(captureFPS: Double, dropped: Int) {
        lock.lock()
        stats.captureFPS = captureFPS
        stats.droppedFrames = dropped
        lock.unlock()
    }

    // MARK: - Broadcasting

    /// Pushes one JPEG to every connected client.
    ///
    /// Uses `.idempotent` so a slow client cannot apply back-pressure to the
    /// encoder thread — the same principle as the capture queue: shed frames
    /// rather than accumulate latency.
    public func broadcast(jpeg: Data, encodeMillis: Double, captureFPS: Double, dropped: Int) {
        lock.lock()
        let targets = Array(clients.values)
        stats.encodeMillis = encodeMillis
        stats.captureFPS = captureFPS
        stats.lastFrameBytes = jpeg.count
        stats.droppedFrames = dropped
        lock.unlock()

        guard !targets.isEmpty else { return }

        var payload = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        payload.append(jpeg)
        payload.append(Data("\r\n".utf8))

        for connection in targets {
            connection.send(content: payload, completion: .idempotent)
        }

        lock.lock()
        stats.framesSent += 1
        stats.bytesSent += payload.count
        windowFrames += 1
        windowBytes += payload.count
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - windowStart
        if elapsed >= 1.0 {
            stats.sentFPS = Double(windowFrames) / elapsed
            stats.megabitsPerSecond = Double(windowBytes) * 8.0 / elapsed / 1_000_000.0
            windowStart = now
            windowFrames = 0
            windowBytes = 0
        }
        lock.unlock()
    }

    /// Viewer page: fullscreen image plus the debug HUD the build plan requires
    /// from Phase 1 onward. Press H to hide it, F for fullscreen.
    static let viewerPage = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Display Share</title>
        <style>
          :root { color-scheme: dark; }
          html, body { margin:0; padding:0; height:100%; background:#000; overflow:hidden; }
          #screen { width:100vw; height:100vh; object-fit:contain; display:block; }
          #hud {
            position:fixed; top:12px; left:12px; padding:10px 14px;
            font:12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
            color:#e8e8e8; background:rgba(0,0,0,.62); border:1px solid rgba(255,255,255,.16);
            border-radius:8px; backdrop-filter:blur(8px); pointer-events:none; white-space:pre;
          }
          #hud.hidden { display:none; }
          .k { color:#8b96a5; }
        </style>
        </head>
        <body>
        <img id="screen" src="/stream" alt="Remote display">
        <div id="hud">connecting…</div>
        <script>
          const hud = document.getElementById('hud');
          const img = document.getElementById('screen');

          // Client-side arrival rate, measured independently of what the
          // server thinks it sent.
          let arrivals = [], lastPaint = performance.now();
          const tick = () => {
            const now = performance.now();
            arrivals.push(now - lastPaint);
            lastPaint = now;
            if (arrivals.length > 60) arrivals.shift();
            requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);

          const pad = (s, n) => String(s).padStart(n);
          async function refresh() {
            try {
              const r = await fetch('/stats', { cache: 'no-store' });
              const s = await r.json();
              const avg = arrivals.length
                ? arrivals.reduce((a, b) => a + b, 0) / arrivals.length : 0;
              hud.textContent =
                `capture   ${pad(s.captureFPS, 6)} fps\\n` +
                `sent      ${pad(s.sentFPS, 6)} fps\\n` +
                `encode    ${pad(s.encodeMs, 6)} ms\\n` +
                `frame     ${pad(s.frameKB, 6)} KB\\n` +
                `bandwidth ${pad(s.mbps, 6)} Mbps\\n` +
                `dropped   ${pad(s.dropped, 6)}\\n` +
                `clients   ${pad(s.clients, 6)}\\n` +
                `paint     ${pad(avg.toFixed(1), 6)} ms`;
            } catch (e) {
              hud.textContent = 'stats unavailable';
            }
          }
          setInterval(refresh, 500);
          refresh();

          addEventListener('keydown', (e) => {
            const k = e.key.toLowerCase();
            if (k === 'h') hud.classList.toggle('hidden');
            if (k === 'f') {
              if (document.fullscreenElement) document.exitFullscreen();
              else document.documentElement.requestFullscreen();
            }
          });

          // MJPEG connections die when the sender restarts; reconnect rather
          // than leaving the user on a frozen frame.
          img.addEventListener('error', () => {
            setTimeout(() => { img.src = '/stream?t=' + Date.now(); }, 500);
          });
        </script>
        </body>
        </html>
        """
}
