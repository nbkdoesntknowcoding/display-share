import { invoke, Channel } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  codecStringFromAnnexB,
  decodeVideoMessage,
  type ControlMessage,
  type ReceiverPanel,
} from "./protocol";

/**
 * Display Share receiver frontend.
 *
 * The Rust backend owns the socket; this file only decodes and paints. Frames
 * arrive as raw bytes over a Tauri Channel, so nothing is JSON-encoded on the
 * hot path.
 */

const canvas = document.getElementById("screen") as HTMLCanvasElement;
const ctx = canvas.getContext("2d", { alpha: false })!;
const hud = document.getElementById("hud") as HTMLDivElement;
const overlay = document.getElementById("overlay") as HTMLDivElement;
const addressInput = document.getElementById("address") as HTMLInputElement;
const connectButton = document.getElementById("connect") as HTMLButtonElement;

let decoder: VideoDecoder | null = null;
let configuredCodec: string | null = null;
let panel: ReceiverPanel = { width: 1920, height: 1080, scale: 1, refreshRate: 60 };

let decodedFrames = 0;
let decodeErrors = 0;
let paintedInWindow = 0;
let bytesInWindow = 0;
let fps = 0;
let mbps = 0;
let lastDecodeMs = 0;
let lastTimestamp = 0;
let windowStart = performance.now();
const decodeStarts = new Map<number, number>();

/**
 * MEASURED (macOS 26.2 / Chromium, 1080p60): the hardware H.264 decoder carries
 * a ~69ms pipeline while software decode of the same stream lands at ~3ms
 * one-way. Latency is the product, so software is the default.
 *
 * This is not settled for THIS hardware: software decode costs CPU, and on a
 * low-power laptop the trade-off may invert. The toggle stays user-visible so
 * the choice can be re-measured on the real receiver rather than assumed.
 */
type Acceleration = "prefer-software" | "prefer-hardware" | "no-preference";
let acceleration: Acceleration =
  (localStorage.getItem("ds.acceleration") as Acceleration) ?? "prefer-software";

function setStatus(text: string, visible = true) {
  overlay.textContent = text;
  overlay.style.display = visible ? "flex" : "none";
}

function setupDecoder(codec: string) {
  closeDecoder();
  decoder = new VideoDecoder({
    output: (frame) => {
      const started = decodeStarts.get(frame.timestamp);
      if (started !== undefined) {
        lastDecodeMs = performance.now() - started;
        decodeStarts.delete(frame.timestamp);
      }
      decodedFrames++;

      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth;
        canvas.height = frame.displayHeight;
      }
      ctx.drawImage(frame, 0, 0);
      paintedInWindow++;
      frame.close();
      setStatus("", false);
    },
    error: () => {
      decodeErrors++;
      // The GOP is unusable; ask for a fresh IDR rather than showing corruption.
      sendControl({ type: "request_keyframe" });
    },
  });

  // ---------------------------------------------------------------------
  // `description` is deliberately OMITTED. Supplying it switches WebCodecs to
  // AVCC mode, which expects length-prefixed NALUs, and decoding this Annex-B
  // stream then fails SILENTLY. See protocol/SPEC.md §3.1.
  // ---------------------------------------------------------------------
  decoder.configure({
    codec,
    optimizeForLatency: true,
    hardwareAcceleration: acceleration,
  });
  configuredCodec = codec;
}

function closeDecoder() {
  if (decoder) {
    try {
      decoder.close();
    } catch {
      /* already closed */
    }
  }
  decoder = null;
  configuredCodec = null;
  decodeStarts.clear();
}

function handleFrame(bytes: Uint8Array) {
  bytesInWindow += bytes.length;

  const result = decodeVideoMessage(bytes);
  if (!result.ok) {
    decodeErrors++;
    return;
  }
  const { isKeyframe, payload } = result.message;
  // Safe here: real timestamps are far below 2^53 (see protocol.ts).
  const timestampMicros = Number(result.message.timestampMicros);

  if (!decoder) {
    // Cannot start mid-GOP: wait for a keyframe, whose SPS gives the codec.
    if (!isKeyframe) return;
    const codec = codecStringFromAnnexB(payload);
    if (!codec) return;
    setupDecoder(codec);
  }

  lastTimestamp = timestampMicros;
  decodeStarts.set(timestampMicros, performance.now());
  try {
    decoder!.decode(
      new EncodedVideoChunk({
        type: isKeyframe ? "key" : "delta",
        timestamp: timestampMicros,
        data: payload,
      })
    );
  } catch {
    decodeErrors++;
  }
}

async function sendControl(message: Record<string, unknown>) {
  try {
    await invoke("send_control", { message: JSON.stringify(message) });
  } catch {
    /* not connected */
  }
}

async function connect(url: string) {
  closeDecoder();
  setStatus(`Connecting to ${url}…`);

  panel = await invoke<ReceiverPanel>("detect_panel");
  // The browser knows the refresh rate the compositor is actually running at
  // better than the Rust side does.
  panel.refreshRate = Math.round(await measureRefreshRate());

  const channel = new Channel<ArrayBuffer>();
  channel.onmessage = (buffer) => handleFrame(new Uint8Array(buffer));

  try {
    await invoke("connect", { url, panel, onFrame: channel });
    setStatus("Disconnected. Reconnecting…");
    setTimeout(() => connect(url), 1500);
  } catch (e) {
    setStatus(`${e}\n\nRetrying…`);
    setTimeout(() => connect(url), 2500);
  }
}

/** Samples rAF intervals to infer the panel's actual refresh rate. */
function measureRefreshRate(): Promise<number> {
  return new Promise((resolve) => {
    const times: number[] = [];
    let last = performance.now();
    let count = 0;
    const tick = () => {
      const now = performance.now();
      times.push(now - last);
      last = now;
      if (++count < 20) requestAnimationFrame(tick);
      else {
        times.sort((a, b) => a - b);
        const median = times[Math.floor(times.length / 2)];
        resolve(median > 0 ? Math.min(240, 1000 / median) : 60);
      }
    };
    requestAnimationFrame(tick);
  });
}

listen<string>("ds://control", (event) => {
  let message: ControlMessage;
  try {
    message = JSON.parse(event.payload);
  } catch {
    return;
  }
  switch (message.type) {
    case "welcome":
      setStatus("", false);
      break;
    case "video_format":
      // Geometry changed; the next access unit is a keyframe, so rebuild the
      // decoder from its SPS rather than guessing.
      closeDecoder();
      break;
    case "error":
      setStatus(`${message.code}: ${message.message}`);
      break;
    default:
      // SPEC §4: unknown types are ignored so either side can add messages.
      break;
  }
});

listen("ds://disconnected", () => setStatus("Disconnected. Reconnecting…"));

// --- HUD --------------------------------------------------------------------

setInterval(() => {
  const now = performance.now();
  const elapsed = (now - windowStart) / 1000;
  if (elapsed >= 1) {
    fps = paintedInWindow / elapsed;
    mbps = (bytesInWindow * 8) / elapsed / 1e6;
    paintedInWindow = 0;
    bytesInWindow = 0;
    windowStart = now;
  }

  const pad = (v: string | number, n: number) => String(v).padStart(n);
  hud.textContent =
    `codec     ${pad(configuredCodec ?? "—", 14)}\n` +
    `accel     ${pad(acceleration.replace("prefer-", ""), 14)}\n` +
    `panel     ${pad(`${panel.width}x${panel.height} @${panel.scale}x`, 14)}\n` +
    `painted   ${pad(fps.toFixed(1), 14)} fps\n` +
    `decode    ${pad(lastDecodeMs.toFixed(2), 14)} ms\n` +
    `bandwidth ${pad(mbps.toFixed(2), 14)} Mbps\n` +
    `frames    ${pad(decodedFrames, 14)}\n` +
    `errors    ${pad(decodeErrors, 14)}\n` +
    `queue     ${pad(decoder?.decodeQueueSize ?? 0, 14)}\n` +
    `\n[F] fullscreen  [H] hud  [K] keyframe  [A] accel`;

  // SPEC §4.6 — echo the last rendered timestamp so the sender can measure a
  // round trip against its own clock.
  void sendControl({
    type: "stats",
    decodedFrames,
    droppedFrames: decodeErrors,
    decodeMillis: Number(lastDecodeMs.toFixed(2)),
    queuedFrames: decoder?.decodeQueueSize ?? 0,
    lastTimestamp,
  });
}, 500);

// --- Input ------------------------------------------------------------------

let fullscreen = false;
addEventListener("keydown", (event) => {
  switch (event.key.toLowerCase()) {
    case "f":
      fullscreen = !fullscreen;
      void invoke("set_fullscreen", { enabled: fullscreen });
      break;
    case "h":
      hud.classList.toggle("hidden");
      break;
    case "k":
      void sendControl({ type: "request_keyframe" });
      break;
    case "a": {
      // Round-trip the decode path so the trade-off can be measured here.
      const order: Acceleration[] = ["prefer-software", "prefer-hardware", "no-preference"];
      acceleration = order[(order.indexOf(acceleration) + 1) % order.length];
      localStorage.setItem("ds.acceleration", acceleration);
      closeDecoder();
      void sendControl({ type: "request_keyframe" });
      break;
    }
  }
});

connectButton.addEventListener("click", () => {
  const host = addressInput.value.trim();
  if (!host) return;
  localStorage.setItem("ds.host", host);
  const url = host.startsWith("ws://") || host.startsWith("wss://") ? host : `ws://${host}:8788`;
  void connect(url);
});

// DS_HOST wins over the remembered host, so a test run is deterministic.
const presetHost = await invoke<string | null>("default_host").catch(() => null);
addressInput.value = presetHost ?? localStorage.getItem("ds.host") ?? "";
addressInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") connectButton.click();
});

setStatus("Enter the Mac's address and press Connect.");

// Auto-connect when a host is remembered, so the app is one click on relaunch.
if (addressInput.value) connectButton.click();
