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

    /// Where the viewer page should point its WebSocket.
    public var webSocketPort: UInt16

    public init(port: UInt16 = 8787, webSocketPort: UInt16 = 8788) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.webSocketPort = webSocketPort
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
            // Strip the query string: "/?hw=software" must still route to "/".
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

            switch path {
            case "/stream":
                self.startStreaming(to: connection)
            case "/stats":
                self.sendJSON(self.statistics, on: connection)
            case "/", "/index.html":
                // Task 2.4 default: the H.264 WebCodecs client.
                self.sendHTML(ViewerPages.webCodecs(socketPort: self.webSocketPort), on: connection)
            case "/mjpeg":
                // Phase 1 path, kept for the side-by-side latency comparison.
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

        // X-Sent-Micros lets a fetch-based client measure one-way latency
        // exactly as the WebCodecs client does, so the two paths compare fairly.
        let sentMicros = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000)
        var payload = Data(
            "--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\nX-Sent-Micros: \(sentMicros)\r\n\r\n".utf8)
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
    /// Phase 1 MJPEG client, kept for the Task 2.4 latency comparison.
    ///
    /// Uses fetch + ReadableStream rather than an <img> tag so it can read the
    /// per-part X-Sent-Micros header. An <img> gives no per-frame hook, which
    /// would make the two paths impossible to compare on equal terms.
    static let viewerPage = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Display Share — MJPEG</title>
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
        </style>
        </head>
        <body>
        <canvas id="screen"></canvas>
        <div id="hud">connecting…</div>
        <script>
        const canvas = document.getElementById('screen');
        const ctx = canvas.getContext('2d');
        const hud = document.getElementById('hud');
        const CF_EPOCH_OFFSET_MS = 978307200000;
        const sameMachine = ['localhost', '127.0.0.1', '::1'].includes(location.hostname);

        let painted = 0, frames = 0, bytes = 0, decodeMs = 0;
        let windowStart = performance.now(), fps = 0, mbps = 0;
        let latencySamples = [];

        function median(a) {
          if (!a.length) return 0;
          const s = [...a].sort((x, y) => x - y);
          return s[Math.floor(s.length / 2)];
        }

        // Minimal multipart/x-mixed-replace reader.
        async function run() {
          const res = await fetch('/stream', { cache: 'no-store' });
          const reader = res.body.getReader();
          let buf = new Uint8Array(0);
          const enc = new TextEncoder();
          const BOUNDARY = enc.encode('--displayshareframe');

          const indexOf = (hay, needle, from) => {
            outer: for (let i = from; i <= hay.length - needle.length; i++) {
              for (let j = 0; j < needle.length; j++) if (hay[i+j] !== needle[j]) continue outer;
              return i;
            }
            return -1;
          };

          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            const merged = new Uint8Array(buf.length + value.length);
            merged.set(buf); merged.set(value, buf.length);
            buf = merged;

            while (true) {
              const start = indexOf(buf, BOUNDARY, 0);
              if (start < 0) break;
              const headerEnd = indexOf(buf, enc.encode('\\r\\n\\r\\n'), start);
              if (headerEnd < 0) break;
              const headerText = new TextDecoder().decode(buf.subarray(start, headerEnd));
              const lenMatch = /Content-Length:\\s*(\\d+)/i.exec(headerText);
              const tsMatch = /X-Sent-Micros:\\s*(\\d+)/i.exec(headerText);
              if (!lenMatch) break;
              const bodyStart = headerEnd + 4;
              const bodyLen = parseInt(lenMatch[1], 10);
              if (buf.length < bodyStart + bodyLen) break;

              const jpeg = buf.subarray(bodyStart, bodyStart + bodyLen);
              bytes += bodyLen; frames++;
              const t0 = performance.now();
              const bmp = await createImageBitmap(new Blob([jpeg], { type: 'image/jpeg' }));
              decodeMs = performance.now() - t0;
              if (canvas.width !== bmp.width) { canvas.width = bmp.width; canvas.height = bmp.height; }
              ctx.drawImage(bmp, 0, 0);
              bmp.close();
              painted++;

              if (sameMachine && tsMatch) {
                const sentMs = Number(tsMatch[1]) / 1000 + CF_EPOCH_OFFSET_MS;
                const oneWay = Date.now() - sentMs;
                if (oneWay >= 0 && oneWay < 2000) {
                  latencySamples.push(oneWay);
                  if (latencySamples.length > 120) latencySamples.shift();
                }
              }
              buf = buf.subarray(bodyStart + bodyLen);
            }
          }
        }

        setInterval(() => {
          const now = performance.now();
          const elapsed = (now - windowStart) / 1000;
          if (elapsed >= 1) {
            fps = painted / elapsed;
            mbps = bytes * 8 / elapsed / 1e6;
            painted = 0; bytes = 0; windowStart = now;
          }
          const pad = (s, n) => String(s).padStart(n);
          hud.textContent =
            `codec     ${pad('mjpeg', 12)}\\n` +
            `painted   ${pad(fps.toFixed(1), 12)} fps\\n` +
            `decode    ${pad(decodeMs.toFixed(2), 12)} ms\\n` +
            `bandwidth ${pad(mbps.toFixed(2), 12)} Mbps\\n` +
            `frames    ${pad(frames, 12)}\\n` +
            (sameMachine
              ? `latency   ${pad(median(latencySamples).toFixed(1), 12)} ms  (one-way, shared clock)`
              : `latency   ${pad('n/a', 12)}  (needs shared clock)`);
        }, 500);

        run().catch(e => { hud.textContent = 'stream error: ' + e; });
        </script>
        </body>
        </html>
        """
}
