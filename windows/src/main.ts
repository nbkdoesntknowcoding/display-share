import { invoke, Channel } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getVersion } from "@tauri-apps/api/app";
import {
  codecStringFromAnnexB,
  decodeVideoMessage,
  type ControlMessage,
  type ReceiverPanel,
} from "./protocol";
import { InputCapture } from "./input";
import { applyUpdate, checkForUpdate } from "./updater";

/**
 * Display Share receiver frontend.
 *
 * The Rust backend owns the socket; this file only decodes and paints. Frames
 * arrive as raw bytes over a Tauri Channel, so nothing is JSON-encoded on the
 * hot path.
 */

const canvas = document.getElementById("screen") as HTMLCanvasElement;
// desynchronized decouples painting from the compositor's frame cadence, which
// is the difference between showing a frame now and showing it at the next
// composite. alpha:false avoids a needless blend of an opaque video.
const ctx = canvas.getContext("2d", { alpha: false, desynchronized: true })!;
const hud = document.getElementById("hud") as HTMLDivElement;
const overlay = document.getElementById("overlay") as HTMLDivElement;
const addressInput = document.getElementById("address") as HTMLInputElement;
const connectButton = document.getElementById("connect") as HTMLButtonElement;

interface Identity { deviceId: string; deviceName: string; token?: string }
let identity: Identity | null = null;

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
// no-preference lets the engine pick, which is right far more often than
// forcing either. This previously defaulted to prefer-software on the strength
// of one measurement claiming software was 22x faster — implausible enough that
// inheriting it was a mistake. [A] still cycles the modes, and the HUD now
// reports decode cost, so the choice can be settled by measurement per machine.
let acceleration: Acceleration =
  (localStorage.getItem("ds.acceleration") as Acceleration) ?? "no-preference";

const messageEl = document.getElementById("message") as HTMLDivElement;
const card = document.getElementById("card");
/// Whether the user wants the HUD when a stream is running. Persisted so the
/// preference survives a reconnect and a restart.
let hudWanted = localStorage.getItem("ds.hud") !== "0";

function setStatus(text: string, visible = true) {
  // Write to the MESSAGE element, never to #overlay. Setting overlay.textContent
  // replaces every child of the overlay — the discovered-sender list, the PIN
  // row and the manual address field with its Connect and Rescan buttons — with
  // a single text node. The first status update at startup therefore deleted the
  // entire UI, leaving only the sentence and no way to type an address, and
  // every later update wrote into detached nodes.
  if (messageEl.textContent !== text) {
    // Restart the fade rather than letting a repeated class do nothing.
    messageEl.classList.remove("changed");
    void messageEl.offsetWidth;
    messageEl.classList.add("changed");
  }
  messageEl.textContent = text;
  overlay.style.display = visible ? "flex" : "none";
  // The HUD reports a live stream's statistics. While the overlay is up there is
  // no live stream, so leaving it on shows stale numbers bleeding through.
  // The HUD describes a live stream, so it goes away while the overlay is up —
  // and MUST come back when the stream returns. Hiding it here without
  // restoring it left the HUD gone for the whole session after connecting,
  // needing two presses of H to recover.
  hud.classList.toggle("hidden", visible || !hudWanted);
}

// --- Latency measurement (Task 10.1) ----------------------------------------
// The sender's timestamps come from ITS monotonic clock, so they cannot be
// compared to ours directly — the offset is unknown. But the offset is CONSTANT,
// so it cancels: track (arrival - senderTimestamp) and subtract the smallest
// value ever seen. What remains is delay above the best path this session has
// managed, which is exactly the queuing and jitter that accumulates and gets
// felt as lag. A steady stream sits near zero however far apart the clocks are.
let bestOffsetMs = Number.POSITIVE_INFINITY;
let queueingMs = 0;
let peakQueueingMs = 0;
/// Gap between consecutive arrivals, which exposes a stalling link even when
/// the average frame rate looks healthy.
let lastArrival = 0;
let worstGapMs = 0;

function noteArrival(senderTimestampMicros: number) {
  const now = performance.now();
  const offset = now - senderTimestampMicros / 1000;
  if (offset < bestOffsetMs) bestOffsetMs = offset;
  queueingMs = offset - bestOffsetMs;
  if (queueingMs > peakQueueingMs) peakQueueingMs = queueingMs;
  if (lastArrival) {
    const gap = now - lastArrival;
    if (gap > worstGapMs) worstGapMs = gap;
  }
  lastArrival = now;
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
      // The first frame is the moment the shortcut is worth knowing, and the
      // only moment the overlay is not covering the screen to say it.
      showFirstRunHint();
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
  noteArrival(timestampMicros);
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
    await invoke("connect", { url, panel, identity, onFrame: channel });
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
    case "pointer_release":
      // The Mac says the cursor came home. Drop the lock and resume absolute
      // positions, otherwise the user is stuck roaming with no way back.
      input.releasePointer();
      break;
    case "video_format":
      // Geometry changed; the next access unit is a keyframe, so rebuild the
      // decoder from its SPS rather than guessing.
      closeDecoder();
      break;
    case "pairing_required_marker":
      break;
    case "paired":
      // Store the token so the next launch is one click (SPEC §4.8).
      if (identity && message.token) {
        identity.token = message.token;
        localStorage.setItem("ds.token", message.token);
        if (message.sender) localStorage.setItem("ds.senderName", message.sender);
      }
      hidePinPrompt();
      setStatus("Paired. Connecting…");
      break;
    case "error":
      if (message.code === "input_unavailable") {
        // Forwarding is on but the Mac cannot inject; say so and stop pretending.
        input.setEnabled(false);
        setStatus(`${message.message}`);
        break;
      }
      if (message.code === "pairing_required") {
        showPinPrompt(message.message ?? "Enter the PIN shown on the Mac.");
      } else if (message.code === "pair_rejected") {
        showPinPrompt(message.message ?? "Incorrect PIN.", true);
      } else {
        setStatus(`${message.code}: ${message.message}`);
      }
      break;
    default:
      // SPEC §4: unknown types are ignored so either side can add messages.
      break;
  }
});

listen("ds://disconnected", () => setStatus("Disconnected. Reconnecting…"));

// --- Input forwarding (SPEC §4.10) ------------------------------------------

const inputBadge = document.getElementById("input-badge") as HTMLDivElement;

const input = new InputCapture({
  canvas,
  send: (events) => void sendControl({ type: "input", events }),
  onEnabledChanged: (enabled) => {
    // Unmissable state: driving the Mac by accident is worse than an ugly badge.
    inputBadge.textContent = enabled ? "⌨ INPUT → MAC  ·  F8 to release" : "";
    inputBadge.classList.toggle("active", enabled);
    if (!enabled) input.releaseAll();
  },
});

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
    // Peaks describe the last second, not the whole session, or one early
    // hiccup would mask everything that follows.
    peakQueueingMs = 0;
    worstGapMs = 0;
  }

  // Rows rather than padded monospace: the HUD is read at a glance mid-session,
  // and latency is the number that matters now, so it leads and turns amber when
  // delay is climbing.
  const rows: Array<[string, string, string?]> = [
    ["delay", `${queueingMs.toFixed(0)} ms`, queueingMs > 60 ? "lead warn" : "lead"],
    ["painted", `${fps.toFixed(0)} fps`],
    ["decode", `${lastDecodeMs.toFixed(1)} ms`],
    ["peak / gap", `${peakQueueingMs.toFixed(0)} / ${worstGapMs.toFixed(0)} ms`,
      worstGapMs > 120 ? "warn" : undefined],
    ["bandwidth", `${mbps.toFixed(1)} Mbps`],
    ["queue", String(decoder?.decodeQueueSize ?? 0)],
    ["codec", configuredCodec ?? "—"],
    ["accel", acceleration.replace("prefer-", "")],
    ["panel", `${panel.width}x${panel.height} @${panel.scale}x`],
  ];
  if (decodeErrors > 0) rows.push(["errors", String(decodeErrors), "warn"]);

  hud.replaceChildren(
    ...rows.map(([label, value, cls]) => {
      const row = document.createElement("div");
      row.className = cls ? `hud-row ${cls}` : "hud-row";
      const l = document.createElement("span");
      l.className = "hud-label";
      l.textContent = label;
      const v = document.createElement("span");
      v.className = "hud-value";
      v.textContent = value;
      row.append(l, v);
      return row;
    })
  );
  const keys = document.createElement("div");
  keys.className = "hud-keys";
  // Shortcuts named where they are used, rather than left to be discovered.
  keys.innerHTML =
    "<kbd>F</kbd> fullscreen &nbsp; <kbd>H</kbd> hide &nbsp; " +
    "<kbd>K</kbd> keyframe &nbsp; <kbd>A</kbd> decoder";
  hud.appendChild(keys);

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
  // While forwarding, letters belong to the Mac — only F8 is ours.
  if (input.isEnabled && event.code !== "F8") return;
  switch (event.key.toLowerCase()) {
    case "f":
      fullscreen = !fullscreen;
      void invoke("set_fullscreen", { enabled: fullscreen });
      break;
    case "h":
      // Remember the choice, so reconnecting does not overrule the user.
      hudWanted = !hudWanted;
      hud.classList.toggle("hidden", !hudWanted);
      localStorage.setItem("ds.hud", hudWanted ? "1" : "0");
      break;
    case "k":
      void sendControl({ type: "request_keyframe" });
      break;
    case "f8":
      // Deliberately not a plain letter: those are forwarded to the Mac while
      // input is active, so the release key must be one we never forward.
      input.toggle();
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

// --- Discovery + pairing UI -------------------------------------------------

const senderList = document.getElementById("senders") as HTMLDivElement;
const rescanButton = document.getElementById("rescan") as HTMLButtonElement;
const pinRow = document.getElementById("pin-row") as HTMLDivElement;
const pinInput = document.getElementById("pin") as HTMLInputElement;
const pinSubmit = document.getElementById("pin-submit") as HTMLButtonElement;
const pinMessage = document.getElementById("pin-message") as HTMLDivElement;

function showPinPrompt(message: string, isError = false) {
  pinRow.style.display = "flex";
  pinMessage.style.display = "block";
  pinMessage.textContent = message;
  pinMessage.classList.toggle("error", isError);
  // While a PIN is pending, pairing IS the step: the manual address row is
  // stood down so there is one primary action rather than two blue buttons
  // competing for the same decision.
  card?.classList.add("pairing");
  overlay.style.display = "flex";
  pinInput.value = "";
  pinInput.focus();
}

function hidePinPrompt() {
  pinRow.style.display = "none";
  pinMessage.style.display = "none";
  card?.classList.remove("pairing");
}

pinSubmit.addEventListener("click", () => {
  const pin = pinInput.value.trim();
  if (pin.length !== 4 || !identity) return;
  void sendControl({
    type: "pair",
    pin,
    deviceId: identity.deviceId,
    deviceName: identity.deviceName,
  });
  pinMessage.textContent = "Pairing…";
});
pinInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") pinSubmit.click();
});

interface DiscoveredSender {
  name: string;
  host: string;
  port: number;
  addresses: string[];
  requires_pairing: boolean;
}

async function scanForSenders() {
  senderList.textContent = "Looking for Macs on this network…";
  let senders: DiscoveredSender[] = [];
  try {
    senders = await invoke<DiscoveredSender[]>("discover_senders", { timeoutMs: 2500 });
  } catch (e) {
    senderList.textContent = `Discovery unavailable (${e}). Enter an address below.`;
    return;
  }
  if (senders.length === 0) {
    senderList.textContent =
      "No senders found. Check both devices are on the same network, or enter an address below.";
    return;
  }
  senderList.textContent = "";
  for (const sender of senders) {
    const target = sender.addresses[0] ?? sender.host;
    const button = document.createElement("button");
    button.className = "sender";
    // Staggered by position: a list that lands together reads as a flash.
    button.style.animationDelay = `${senderList.childElementCount * 40}ms`;
    button.textContent = `${sender.name} — ${target}:${sender.port}`;
    button.addEventListener("click", () => void connect(`ws://${target}:${sender.port}`));
    senderList.appendChild(button);
  }
}

rescanButton.addEventListener("click", () => void scanForSenders());

// Identity is needed before any connection attempt, since a stored token is
// what makes reconnecting one click.
identity = await invoke<Identity>("device_identity").catch(() => null);
if (identity) {
  const stored = localStorage.getItem("ds.token");
  if (stored) identity.token = stored;
}

setStatus("Looking for senders…");
void scanForSenders();

// --- Updates (Tasks 7.2 / 9.1) ----------------------------------------------
// Applied automatically at launch. Chosen deliberately after the risk was
// raised: every payload is verified against the minisign public key in
// tauri.conf.json, whose private half lives in GitHub secrets, so the download
// cannot be tampered with even though the installer itself carries no code
// signing certificate. Unsigned is not the same thing as unverified.
//
// This runs BEFORE the auto-connect below on purpose. Replacing the binary
// underneath a live session would drop the stream and read as a crash, and at
// launch there is no session yet — so this is the only safe moment.
const versionLabel = document.getElementById("version") as HTMLSpanElement | null;

/// Shows which version is running.
///
/// Not decoration. Updates now apply themselves silently at launch, so without
/// this there is no way to tell what you are on, whether an update landed, or
/// whether the update path is broken — the three questions that follow removing
/// a visible "Update" button.
async function showVersion(suffix = "") {
  if (!versionLabel) return;
  try {
    versionLabel.textContent = `v${await getVersion()}${suffix}`;
  } catch {
    versionLabel.textContent = suffix.trim();
  }
}

void showVersion();

async function applyUpdateOnLaunch(): Promise<boolean> {
  let status;
  try {
    status = await checkForUpdate();
  } catch (error) {
    // A failed check must never stop the app being used offline — but it must
    // not be invisible either, or a broken update path looks identical to
    // being up to date.
    versionLabel?.classList.add("warn");
    void showVersion(" · update check failed");
    console.warn("update check failed", error);
    return false;
  }
  if (!status.available || !status.version) return false;

  const bar = document.createElement("div");
  bar.id = "update-bar";
  const label = document.createElement("span");
  label.textContent = `Updating to ${status.version}…`;
  bar.appendChild(label);
  document.body.appendChild(bar);

  try {
    await applyUpdate((pct) => {
      label.textContent =
        pct < 100 ? `Updating to ${status.version}… ${pct}%` : "Restarting…";
    });
    return true;
  } catch (error) {
    // Say so and carry on with the version already installed, rather than
    // leaving the user staring at a stalled progress line.
    label.textContent = `Update failed, continuing on this version: ${error}`;
    return false;
  }
}

void (async () => {
  const restarting = await applyUpdateOnLaunch();
  if (restarting) return;

  // Auto-connect when a host is remembered AND we hold a token, so a paired
  // receiver reconnects without interaction.
  if (addressInput.value && identity?.token) connectButton.click();
})();

// ---------------------------------------------------------- Tasks 8.2 / 8.4
// Sharing this PC's screen so a Mac can view it — the reverse of everything
// above. Only one direction runs at a time; the backend refuses both ways
// round, because two machines each capturing the other is a feedback loop that
// saturates the link and confuses the adaptive bitrate controller.
const shareButton = document.getElementById("share") as HTMLButtonElement | null;
const stopShareButton = document.getElementById("stop-share") as HTMLButtonElement | null;
const shareStatus = document.getElementById("share-status") as HTMLSpanElement | null;
const shareOutput = document.getElementById("share-output") as HTMLSelectElement | null;

interface DisplayOutput {
  index: number;
  name: string;
  width: number;
  height: number;
  is_primary: boolean;
  attached: boolean;
}

/// Fills the display picker. Failing here must not break the receiver, which is
/// what most people opened this app for.
async function loadOutputs() {
  if (!shareOutput) return;
  try {
    const outputs = (await invoke("list_display_outputs")) as DisplayOutput[];
    shareOutput.innerHTML = "";
    for (const output of outputs) {
      const option = document.createElement("option");
      option.value = String(output.index);
      // Name the role, not just the device: "\\.\DISPLAY2" tells the user
      // nothing about which physical screen it is.
      const role = output.is_primary ? "this screen" : "second screen";
      option.textContent = `${role} — ${output.width}×${output.height} (${output.name})`;
      shareOutput.appendChild(option);
    }
    shareOutput.hidden = outputs.length < 2;
    if (outputs.length < 2 && shareStatus) {
      shareStatus.textContent =
        "Only one display detected — sharing it mirrors this screen. A dummy display adapter adds a second one.";
    }
  } catch {
    shareOutput.hidden = true;
  }
}

void loadOutputs();

shareButton?.addEventListener("click", async () => {
  shareButton.disabled = true;
  if (shareStatus) shareStatus.textContent = "Starting…";
  try {
    const output = shareOutput && !shareOutput.hidden ? Number(shareOutput.value) : 0;
    const info = (await invoke("start_sharing", { output })) as {
      port: number;
      host: string;
    };
    if (shareStatus) {
      // Show the port as well as the name: Bonjour fails often enough on
      // locked-down networks that the manual fallback needs to be visible
      // rather than something to go hunting for.
      shareStatus.textContent = `Sharing as “${info.host}” — on the Mac, choose View a Windows PC (port ${info.port})`;
    }
    if (stopShareButton) stopShareButton.hidden = false;
  } catch (error) {
    if (shareStatus) shareStatus.textContent = `Could not start: ${error}`;
    shareButton.disabled = false;
  }
});

stopShareButton?.addEventListener("click", async () => {
  try {
    await invoke("stop_sharing");
    if (shareStatus) shareStatus.textContent = "Stopped sharing.";
    if (shareButton) shareButton.disabled = false;
    stopShareButton.hidden = true;
  } catch (error) {
    if (shareStatus) shareStatus.textContent = `Could not stop: ${error}`;
  }
});

// --- First-connect hint (Task 10.3) -----------------------------------------
// Shown once ever, then never again. A permanent shortcut bar would be furniture
// on a screen whose whole purpose is to be a display.
const hintEl = document.getElementById("hint") as HTMLDivElement | null;

function showFirstRunHint() {
  if (!hintEl || localStorage.getItem("ds.hinted")) return;
  localStorage.setItem("ds.hinted", "1");
  hintEl.innerHTML = "Press <kbd>H</kbd> for stats · <kbd>F</kbd> for fullscreen";
  hintEl.classList.add("show");
}
