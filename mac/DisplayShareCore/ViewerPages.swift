import Foundation

/// Browser test clients, served by the HTTP server for development.
///
/// The shipping Windows receiver (Phase 3) talks to the WebSocket directly and
/// never fetches these; they exist so the pipeline can be validated in a
/// browser, and so the H.264 and MJPEG paths can be compared side by side.
enum ViewerPages {

    /// Task 2.4 — WebCodecs H.264 client.
    static func webCodecs(socketPort: UInt16) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Display Share — H.264</title>
        <style>
          :root { color-scheme: dark; }
          html, body { margin:0; padding:0; height:100%; background:#000; overflow:hidden; }
          #screen { width:100vw; height:100vh; object-fit:contain; display:block; background:#000; }
          #hud {
            position:fixed; top:12px; left:12px; padding:10px 14px;
            font:12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
            color:#e8e8e8; background:rgba(0,0,0,.62); border:1px solid rgba(255,255,255,.16);
            border-radius:8px; backdrop-filter:blur(8px); pointer-events:none; white-space:pre;
          }
          #hud.hidden { display:none; }
          #banner {
            position:fixed; inset:auto 0 0 0; padding:10px 14px; background:#7f1d1d; color:#fff;
            font:13px/1.4 ui-sans-serif, system-ui; display:none;
          }
        </style>
        </head>
        <body>
        <canvas id="screen"></canvas>
        <div id="hud">connecting…</div>
        <div id="banner"></div>
        <script>
        const WS_PORT = \(socketPort);
        const canvas = document.getElementById('screen');
        const ctx = canvas.getContext('2d');
        const hud = document.getElementById('hud');
        const banner = document.getElementById('banner');

        // CoreFoundation's epoch is 2001-01-01; JS uses 1970. Sender timestamps
        // are CFAbsoluteTime microseconds, so on localhost (one shared system
        // clock) this yields a TRUE one-way sender->paint latency. Over a LAN
        // the two clocks are independent and this figure is meaningless — the
        // HUD says so rather than quietly reporting a fiction.
        const CF_EPOCH_OFFSET_MS = 978307200000;
        const sameMachine = ['localhost', '127.0.0.1', '::1'].includes(location.hostname);

        if (!('VideoDecoder' in window)) {
          banner.style.display = 'block';
          banner.textContent =
            'WebCodecs is unavailable. It requires a secure context: use http://localhost, ' +
            'or serve this page over HTTPS. Over a plain LAN IP the browser disables it.';
        }

        let decoder = null, configuredCodec = null;
        let decoded = 0, dropped = 0, painted = 0;
        let lastDecodeMs = 0, lastTimestamp = 0;
        let bytes = 0, windowStart = performance.now(), fps = 0, mbps = 0;
        let latencySamples = [];
        const decodeStarts = new Map();

        /// SPEC §3.3: the NALU type is the LOW 5 BITS of the header byte, so an
        /// SPS may be 0x67 or 0x27. Matching the whole byte misses it.
        function codecStringFromAnnexB(bytes) {
          for (let i = 0; i + 8 < bytes.length; i++) {
            if (bytes[i] === 0 && bytes[i+1] === 0 && bytes[i+2] === 0 && bytes[i+3] === 1) {
              const nal = bytes[i+4];
              if ((nal & 0x1f) === 7) {
                const hex = (n) => n.toString(16).padStart(2, '0');
                return 'avc1.' + hex(bytes[i+5]) + hex(bytes[i+6]) + hex(bytes[i+7]);
              }
            }
          }
          return null;
        }

        // ?hw=software | prefer-hardware | no-preference — lets the two decode
        // paths be compared without rebuilding, because WebCodecs' hardware
        // decoder can carry a much deeper pipeline than software.
        // MEASURED on macOS 26.2 / Chromium at 1080p60: Chrome's HARDWARE H.264
        // decoder carries a ~69ms pipeline, while software decode of the same
        // stream lands at ~3ms one-way. Latency is the product, so software is
        // the default here and hardware is opt-in via ?hw=hardware.
        // Phase 3 must re-measure on the actual receiver hardware: software
        // decode costs CPU, and the trade-off on a low-power laptop may differ.
        const HW = new URLSearchParams(location.search).get('hw') || 'software';

        function setupDecoder(codec) {
          if (decoder) { try { decoder.close(); } catch (e) {} }
          decoder = new VideoDecoder({
            output: (frame) => {
              const started = decodeStarts.get(frame.timestamp);
              if (started !== undefined) {
                lastDecodeMs = performance.now() - started;
                decodeStarts.delete(frame.timestamp);
              }
              decoded++;
              if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
                canvas.width = frame.displayWidth;
                canvas.height = frame.displayHeight;
              }
              ctx.drawImage(frame, 0, 0);
              painted++;
              frame.close();

              // Use THIS frame's timestamp, not the most recently received
              // one — otherwise this measures "time since the last packet
              // arrived" rather than sender->paint latency for the frame
              // actually on screen.
              if (sameMachine && frame.timestamp) {
                const sentMs = frame.timestamp / 1000 + CF_EPOCH_OFFSET_MS;
                const oneWay = Date.now() - sentMs;
                if (oneWay >= 0 && oneWay < 2000) {
                  latencySamples.push(oneWay);
                  if (latencySamples.length > 120) latencySamples.shift();
                }
              }
            },
            error: (e) => {
              dropped++;
              // A decode error means the GOP is unusable; ask for a fresh IDR
              // rather than showing corruption until the next natural keyframe.
              send({ type: 'request_keyframe' });
            }
          });

          // ---------------------------------------------------------------
          // THE critical line. `description` MUST be omitted: supplying it puts
          // WebCodecs into AVCC mode, where it expects length-prefixed NALUs,
          // and decoding this Annex-B stream then fails SILENTLY.
          // ---------------------------------------------------------------
          const config = { codec, optimizeForLatency: true };
          if (HW === 'software') config.hardwareAcceleration = 'prefer-software';
          else if (HW === 'hardware') config.hardwareAcceleration = 'prefer-hardware';
          decoder.configure(config);
          configuredCodec = codec + (HW ? ' [' + HW + ']' : '');
        }

        let ws = null, reconnectTimer = null;
        function connect() {
          ws = new WebSocket(`ws://${location.hostname}:${WS_PORT}`);
          ws.binaryType = 'arraybuffer';

          ws.onopen = () => {
            send({
              type: 'hello',
              protocolVersion: 1,
              client: 'display-share-browser/0.1.0',
              receiver: {
                width: Math.round(screen.width * devicePixelRatio),
                height: Math.round(screen.height * devicePixelRatio),
                scale: devicePixelRatio,
                refreshRate: 60
              }
            });
          };

          ws.onmessage = (event) => {
            if (typeof event.data === 'string') return handleControl(JSON.parse(event.data));
            handleVideo(new Uint8Array(event.data));
          };

          ws.onclose = () => {
            if (!reconnectTimer) reconnectTimer = setTimeout(() => {
              reconnectTimer = null; connect();
            }, 800);
          };
          ws.onerror = () => { try { ws.close(); } catch (e) {} };
        }

        function send(obj) {
          if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
        }

        function handleControl(msg) {
          if (msg.type === 'error') {
            banner.style.display = 'block';
            banner.textContent = `${msg.code}: ${msg.message}`;
          } else if (msg.type === 'video_format') {
            // Geometry changed; the next access unit is a keyframe, so drop the
            // decoder and rebuild from its SPS.
            if (decoder) { try { decoder.close(); } catch (e) {} decoder = null; configuredCodec = null; }
          }
        }

        function handleVideo(buf) {
          if (buf.length < 16) return;
          const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
          const length = view.getUint32(0);
          if (length !== buf.length - 4) return;      // SPEC §3: reject mismatch
          if (buf[4] !== 1) return;                   // not a video access unit
          const isKey = (buf[5] & 1) === 1;
          // getBigUint64 keeps the full unsigned range; Number() is safe here
          // because microsecond values stay far below 2^53.
          const timestamp = Number(view.getBigUint64(8));
          const payload = buf.subarray(16);

          bytes += buf.length;

          if (!decoder) {
            if (!isKey) return;                        // wait for an IDR
            const codec = codecStringFromAnnexB(payload);
            if (!codec) return;
            setupDecoder(codec);
          }

          lastTimestamp = timestamp;
          decodeStarts.set(timestamp, performance.now());
          try {
            decoder.decode(new EncodedVideoChunk({
              type: isKey ? 'key' : 'delta',
              timestamp,
              data: payload
            }));
          } catch (e) {
            dropped++;
          }
        }

        function median(a) {
          if (!a.length) return 0;
          const s = [...a].sort((x, y) => x - y);
          return s[Math.floor(s.length / 2)];
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
          const lat = median(latencySamples);
          hud.textContent =
            `codec     ${pad(configuredCodec || '—', 12)}\\n` +
            `painted   ${pad(fps.toFixed(1), 12)} fps\\n` +
            `decode    ${pad(lastDecodeMs.toFixed(2), 12)} ms\\n` +
            `bandwidth ${pad(mbps.toFixed(2), 12)} Mbps\\n` +
            `decoded   ${pad(decoded, 12)}\\n` +
            `errors    ${pad(dropped, 12)}\\n` +
            (sameMachine
              ? `latency   ${pad(lat.toFixed(1), 12)} ms  (one-way, shared clock)`
              : `latency   ${pad('n/a', 12)}  (needs shared clock)`);

          // SPEC §4.6 — echo the last rendered timestamp so the sender can
          // measure a round trip against its own clock.
          send({
            type: 'stats', decodedFrames: decoded, droppedFrames: dropped,
            decodeMillis: Number(lastDecodeMs.toFixed(2)),
            queuedFrames: decoder ? decoder.decodeQueueSize : 0,
            lastTimestamp
          });
        }, 500);

        addEventListener('keydown', (e) => {
          const k = e.key.toLowerCase();
          if (k === 'h') hud.classList.toggle('hidden');
          if (k === 'k') send({ type: 'request_keyframe' });
          if (k === 'f') {
            if (document.fullscreenElement) document.exitFullscreen();
            else document.documentElement.requestFullscreen();
          }
        });

        connect();
        </script>
        </body>
        </html>
        """
    }
}
