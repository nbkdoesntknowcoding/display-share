// FIRST, and deliberately so. This module performs the update check at import
// time, before any code below has a chance to fail. v0.9.0 threw during this
// module's initialisation and its update check — further down this same file —
// never ran, stranding every installation that took it. See selfheal.ts.
import { selfHealStarted } from "./selfheal";
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
import { backoffFor, disconnectStatus, humanise, refusalExplanation } from "./errors";
import { installDisabledGuard, setEnabled, setVariant } from "./components/controls";
import { applyWindowClasses } from "./components/window";
import {
  HandoffMeter,
  PresentMeter,
  StageMeter,
  stageRow,
  type HandoffSample,
} from "./timing";

/**
 * Display Share receiver frontend.
 *
 * The Rust backend owns the socket; this file only decodes and paints. Frames
 * arrive as raw bytes over a Tauri Channel, so nothing is JSON-encoded on the
 * hot path.
 */

installDisabledGuard();

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

interface LinkInfo {
  name: string;
  kind: string;
  wired: boolean;
  local_ip: string;
  speed_mbps: number;
  direct: boolean;
}
/// Which adapter this session is running over (Task 10.2). Wi-Fi jitter is the
/// largest remaining source of felt lag, and the fix is a cable rather than a
/// quality trade-off — but "use a cable" is useless advice if the app cannot say
/// what you are on now.
let activeLink: LinkInfo | null = null;
let linkAdvised = false;
/// True between the Mac asking for a PIN and the user answering.
///
/// Without this the reconnect loop fights the prompt: the socket ends, the
/// handler writes "Reconnecting…" over the PIN row, reconnects with the same
/// rejected token, is asked to pair again, and the receiver shows nothing but
/// "Retrying…" for ever while the Mac patiently waits for a PIN.
let awaitingPin = false;
/// Whether the user wants the HUD when a stream is running. Persisted so the
/// preference survives a reconnect and a restart.
/// Off unless asked for (Command 10: "while streaming: zero chrome").
///
/// It used to default ON, so a permanent statistics panel sat over a screen
/// whose entire purpose is to be a screen. The first-run hint teaches H at the
/// exact moment the canvas first appears, and anyone who has turned it on keeps
/// it on across restarts.
let hudWanted = localStorage.getItem("ds.hud") === "1";

const appMark = document.getElementById("app-mark");

/// True once a frame has been painted. It is what separates "has not connected
/// yet" from "was connected and lost it", which look identical to the code that
/// raises the overlay but must not look identical to the user.
let hasLiveFrame = false;

/// Whether the connect card is up. Read from here rather than from
/// `overlay.style.display`, which is no longer what hides it — visibility is a
/// fade now, and two places were still comparing against "none".
let overlayShown = true;

export function isOverlayVisible(): boolean {
  return overlayShown;
}

/**
 * Raises or lowers the connect card (Command 10).
 *
 * The audit's complaint was that the transition from card to canvas was
 * undefined: `display: none` cannot animate, so connecting was a hard cut to
 * black and losing a session replaced the picture with an empty window.
 *
 * Now the card fades, and when it returns over a session that was live the
 * canvas dims to 40% and stays behind it — the last thing the user saw is
 * still there, which is the difference between "this dropped" and "this is
 * broken".
 */
function setOverlayVisible(visible: boolean) {
  overlayShown = visible;
  applyWindowClasses(
    { overlay, canvas, mark: appMark, hud },
    { overlayVisible: visible, hasLiveFrame, hudWanted }
  );
}

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
  // Announced as well as shown: a plain div changing its text tells a screen
  // reader user nothing, so pairing prompts and drops went unnoticed entirely.
  if (text) announce(text);
  setOverlayVisible(visible);
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

// --- Per-stage timing (Phase 3) ---------------------------------------------
// `queueingMs` above says whether delay is climbing. It cannot say what any
// stage costs, because it is measured against the best this session has managed
// rather than against zero. These do: each is a duration between two stamps on
// one clock, so nothing depends on the two machines agreeing about the time.
const handoffMeter = new HandoffMeter();
/**
 * Arrival in this window to the frame being on the canvas — decode plus draw.
 *
 * Reuses `decodeStarts`, which already records arrival: a second map keyed the
 * same way would have to be trimmed on the same paths, and one of them would
 * eventually be missed.
 */
const paintMeter = new StageMeter();
/**
 * Draw finished to the compositor picking the frame up.
 *
 * The last stage on this side, and the one a native presentation surface would
 * exist to remove — so it is measured before anything is rewritten around it.
 */
const presentMeter = new PresentMeter();

function noteArrival(senderTimestampMicros: number) {
  const now = performance.now();
  // timeOrigin included deliberately: the Rust side stamps the wall clock,
  // and performance.now() alone counts from page load, which would make every
  // hand-off look like however long this window has been open.
  handoffMeter.noteArrival(senderTimestampMicros, performance.timeOrigin + now);
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
      // Closed out AFTER the draw, so this covers decode and paint together —
      // the whole of what this window costs a frame. `drawImage` returning is
      // not the same as the pixels being on screen, so this is a floor, not
      // the full story; the compositor's share is not visible from here.
      const drawn = performance.now();
      if (started !== undefined) paintMeter.note(drawn - started);
      // Handing the frame over is not putting it on screen. This measures the
      // wait between the two, which is the part that is ours.
      presentMeter.noteDrawn(drawn, (callback) => requestAnimationFrame(callback));
      paintedInWindow++;
      frame.close();
      hideConnecting();
      // Recorded BEFORE the overlay drops, so the canvas is already marked live
      // and fades in as the card fades out rather than appearing behind it.
      hasLiveFrame = true;
      setStatus("", false);
      // The first frame is the moment the shortcut is worth knowing, and the
      // only moment the overlay is not covering the screen to say it.
      showFirstRunHint();
      void describeLink();
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

/// Attempts since the last success, driving the backoff.
let attempt = 0;
const RETRY_LIMIT = 4;

/// Chooses a connectable address from what mDNS advertised and formats it for a
/// URL.
///
/// Taking addresses[0] blindly produced "invalid authority": mDNS returns IPv6
/// as well as IPv4, and an IPv6 literal is only valid in a URL inside brackets —
/// `ws://fe80::1:8788` cannot be parsed at all.
///
/// IPv4 is preferred where offered. A link-local IPv6 address carries a zone
/// index (`%en0`) that identifies an interface on the machine that resolved it;
/// it is meaningless to a URL and to the other end, so those are skipped rather
/// than dressed up with brackets and hoped for.
export function wsTarget(addresses: string[], host: string): string {
  const ipv4 = addresses.find((a) => /^\d{1,3}(\.\d{1,3}){3}$/.test(a));
  if (ipv4) return ipv4;
  const ipv6 = addresses.find((a) => a.includes(":") && !a.includes("%"));
  if (ipv6) return `[${ipv6}]`;
  return host;
}

/// Builds a URL from a hand-typed address.
///
/// Handles the four things people actually type: a bare address, an address
/// with a port, a bare IPv6 literal, and a full ws:// URL. One colon means a
/// port; more than one means IPv6, which needs brackets.
export function manualUrl(input: string): string {
  const host = input.trim();
  if (!host) return "";
  if (host.startsWith("ws://") || host.startsWith("wss://")) return host;
  if (host.startsWith("[")) {
    return host.includes("]:") ? `ws://${host}` : `ws://${host}:8788`;
  }
  const colons = (host.match(/:/g) ?? []).length;
  if (colons > 1) {
    // A zone index identifies an interface on THIS machine and cannot travel.
    return `ws://[${host.replace(/%.*$/, "")}]:8788`;
  }
  return colons === 1 ? `ws://${host}` : `ws://${host}:8788`;
}

async function connect(url: string) {
  closeDecoder();
  clearFailure();
  showConnecting(connectingLabel(url));

  panel = await invoke<ReceiverPanel>("detect_panel");
  // The browser knows the refresh rate the compositor is actually running at
  // better than the Rust side does.
  panel.refreshRate = Math.round(await measureRefreshRate());

  const channel = new Channel<ArrayBuffer>();
  channel.onmessage = (buffer) => handleFrame(new Uint8Array(buffer));

  try {
    await invoke("connect", { url, panel, identity, onFrame: channel });
    if (awaitingPin) return;
    attempt = 0;
    setStatus("Disconnected. Reconnecting…");
    setTimeout(() => connect(url), 1500);
  } catch (e) {
    // Reconnecting cannot fix a missing PIN, and retrying hides the prompt that
    // can. Leave the pairing UI up and wait for the user.
    if (awaitingPin) return;
    attempt += 1;
    const wait = backoffFor(attempt);
    if (wait === null) {
      // Retrying for ever is how a fixable problem stays hidden. Stop, and show
      // something with a next step in it.
      hideConnecting();
      setStatus("");
      showFailure(String(e), true);
      return;
    }
    setStatus(`Attempt ${attempt + 1} of ${RETRY_LIMIT}…`);
    showFailure(String(e), false);
    setTimeout(() => connect(url), wait);
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

/// An explanation from the Mac that must outlive the disconnect it causes.
///
/// Every reason the sender closes a session arrives as a control message and is
/// then followed, immediately, by the close itself — so without somewhere to
/// keep it, the reconnect handler overwrites the one useful thing on screen.
/// Started as a single flag for "the screen was released"; it needed to be
/// general the moment a second reason turned up, and `busy` was that reason.
let stickyStatus: string | null = null;

listen<string>("ds://control", (event) => {
  let message: ControlMessage;
  try {
    message = JSON.parse(event.payload);
  } catch {
    return;
  }
  switch (message.type) {
    case "welcome":
      // Connected, so nothing from a previous attempt still applies.
      stickyStatus = null;
      setStatus("", false);
      break;
    case "display_released":
      stickyStatus =
        "The Mac released this screen so protected video can play. " +
        "Start sharing there to bring it back.";
      setStatus(stickyStatus);
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
        // A refusal the sender means to stick: shown now AND kept, because the
        // close that follows would otherwise wipe it.
        const explained = refusalExplanation(message.code ?? "");
        stickyStatus = explained;
        setStatus(explained ?? `${message.code}: ${message.message}`);
      }
      break;
    default:
      // SPEC §4: unknown types are ignored so either side can add messages.
      break;
  }
});

// The other half of the hand-off measurement: the Rust side reports when it
// read a sampled frame off the socket, and this window already knows when it
// received the same frame. The two are paired on the sender's timestamp.
listen<HandoffSample>("ds://handoff", (event) => {
  handoffMeter.noteSample(event.payload);
});

listen("ds://disconnected", () => {
  setStatus(disconnectStatus(stickyStatus));
  // A new session starts a new sampler on the Rust side, and its stamps must
  // not be paired against this session's arrivals.
  handoffMeter.reset();
  paintMeter.reset();
  presentMeter.reset();
});

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
    // Judged on the window that just ended, before the peaks are cleared.
    maybeAdviseCable();
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
    ...stageRow("handoff", handoffMeter.summary(), 12),
    ...stageRow("to paint", paintMeter.summary(), 25),
    ...stageRow("to screen", presentMeter.summary(), 25),
    ["peak / gap", `${peakQueueingMs.toFixed(0)} / ${worstGapMs.toFixed(0)} ms`,
      worstGapMs > 120 ? "warn" : undefined],
    ["bandwidth", `${mbps.toFixed(1)} Mbps`],
    ["queue", String(decoder?.decodeQueueSize ?? 0)],
    ["codec", configuredCodec ?? "—"],
    ["accel", acceleration.replace("prefer-", "")],
    ["panel", `${panel.width}x${panel.height} @${panel.scale}x`],
  ];
  if (activeLink) {
    const speed = activeLink.speed_mbps > 0 ? ` · ${activeLink.speed_mbps} Mbps` : "";
    // A cable run straight between two machines self-assigns 169.254.x.x, which
    // is worth calling out: it is the lowest-latency arrangement available.
    const direct = activeLink.direct ? " · direct" : "";
    rows.splice(4, 0, [
      "link",
      `${activeLink.name}${speed}${direct}`,
      activeLink.wired ? undefined : "warn",
    ]);
  }
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
  const url = manualUrl(host);
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
/// Optional: the manual-entry row's duplicate Rescan is gone, and a missing
/// element must never throw during module evaluation — that is how a startup
/// crash takes the whole connect screen with it.
const rescanButton = document.getElementById("rescan") as HTMLButtonElement | null;
const pinRow = document.getElementById("pin-row") as HTMLDivElement;
const pinInput = document.getElementById("pin") as HTMLInputElement;
const pinSubmit = document.getElementById("pin-submit") as HTMLButtonElement;
const pinMessage = document.getElementById("pin-message") as HTMLDivElement;

function showPinPrompt(message: string, isError = false) {
  awaitingPin = true;
  // The stored token has just been refused, so it is worthless. Keeping it would
  // make the next launch auto-connect straight back into this loop.
  if (identity?.token) identity.token = undefined;
  localStorage.removeItem("ds.token");
  pinRow.style.display = "flex";
  pinMessage.style.display = "block";
  pinMessage.textContent = message;
  pinMessage.classList.toggle("error", isError);
  // While a PIN is pending, pairing IS the step: the manual address row is
  // stood down so there is one primary action rather than two blue buttons
  // competing for the same decision.
  card?.classList.add("pairing");
  setOverlayVisible(true);
  pinInput.value = "";
  pinInput.focus();
}

function hidePinPrompt() {
  awaitingPin = false;
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
  // Status goes to the message element, never into the list container: writing
  // into #senders is what deleted the whole UI once before.
  senderList.replaceChildren();
  setStatus("Looking for your Mac…");
  let senders: DiscoveredSender[] = [];
  try {
    senders = await invoke<DiscoveredSender[]>("discover_senders", { timeoutMs: 2500 });
  } catch (e) {
    // The raw text goes to the console, not to the person. This used to render
    // as "Discovery unavailable (TypeError: Cannot read properties of
    // undefined…)" — a JavaScript error as body copy.
    console.warn("discovery failed", e);
    setStatus("Couldn't search this network. Enter your Mac's address instead.");
    showManualEntry(true);
    return;
  }
  if (senders.length === 0) {
    // Written into its own element, never into the list container: replacing a
    // container's contents is what deleted the whole UI once before.
    senderList.replaceChildren();
    showEmptyState(true);
    return;
  }
  senderList.textContent = "";
  for (const sender of senders) {
    const target = wsTarget(sender.addresses, sender.host);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "btn btn--row sender";
    // Staggered by position: a list that lands together reads as a flash.
    button.style.animationDelay = `${senderList.childElementCount * 40}ms`;
    const url = `ws://${target}:${sender.port}`;
    const name = document.createElement("span");
    name.className = "sender-name";
    name.textContent = sender.name;
    const address = document.createElement("span");
    address.className = "sender-address";
    address.textContent = target;
    const wrap = document.createElement("span");
    wrap.append(name, address);
    button.replaceChildren(wrap);
    button.setAttribute("role", "option");
    button.setAttribute("aria-selected", "false");
    // The whole row selects; connecting is the hero button below, so the choice
    // and the action are separate and both obvious.
    button.addEventListener("click", () => selectSender(url, button));
    button.addEventListener("dblclick", () => void connect(url));
    senderList.appendChild(button);
    senderNames.set(url, sender.name);
    showEmptyState(false);
    // Exactly one Mac is the overwhelmingly common case: pre-select it so the
    // user has one thing to press.
    if (senders.length === 1) selectSender(url, button);
  }
}

rescanButton?.addEventListener("click", () => void scanForSenders());

// Identity is needed before any connection attempt, since a stored token is
// what makes reconnecting one click.
identity = await invoke<Identity>("device_identity").catch(() => null);
if (identity) {
  const stored = localStorage.getItem("ds.token");
  if (stored) identity.token = stored;
}

setStatus("Looking for your Mac…");
void scanForSenders();

/// Shows which version is running.
///
/// Updates apply silently, so without this there is no way to tell what you are
/// on, whether one landed, or whether the update path is broken — the three
/// questions that follow removing a visible Update button.
async function showVersion(suffix = "") {
  const label = document.getElementById("version");
  if (!label) return;
  try {
    label.textContent = `v${await getVersion()}${suffix}`;
  } catch {
    label.textContent = suffix.trim();
  }
}

void showVersion();

void (async () => {
  // The check itself already started at import time; this only waits to learn
  // whether the app is about to restart.
  const restarting = await selfHealStarted;
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
  setEnabled(shareButton, false, "Already starting — one moment.");
  if (shareStatus) shareStatus.textContent = "Starting…";
  try {
    const output = shareOutput && !shareOutput.hidden ? Number(shareOutput.value) : 0;
    const info = (await invoke("start_sharing", { output })) as {
      port: number;
      host: string;
    };
    if (shareStatus) {
      shareStatus.textContent = `Sharing as “${info.host}” — on your Mac, open Display Share and choose View a Windows PC.`;
    }
    if (stopShareButton) stopShareButton.hidden = false;
    setEnabled(shareButton, false, "This PC is already sharing its screen.");
  } catch (error) {
    console.error("start_sharing failed", error);
    if (shareStatus) {
      shareStatus.textContent = "Couldn't start sharing this screen. Try again.";
    }
    setEnabled(shareButton, true);
  }
});

stopShareButton?.addEventListener("click", async () => {
  try {
    await invoke("stop_sharing");
    if (shareStatus) shareStatus.textContent = "Stopped sharing.";
    setEnabled(shareButton, true);
    stopShareButton.hidden = true;
  } catch (error) {
    console.error("stop_sharing failed", error);
    if (shareStatus) shareStatus.textContent = "Couldn't stop sharing. Try again.";
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

// --- Which link are we on? (Task 10.2) --------------------------------------
async function describeLink() {
  if (activeLink) return;
  try {
    activeLink = (await invoke("link_info")) as LinkInfo | null;
  } catch {
    // Not knowing the link is not a failure worth showing: the stream works
    // either way and the HUD simply omits the row.
    activeLink = null;
  }
}

/// Suggests a cable once per session, and only when it is actually true — the
/// link is wireless AND measurably costing time. Nagging a link that is behaving
/// would train the user to ignore the one message worth reading.
function maybeAdviseCable() {
  if (linkAdvised || !activeLink || activeLink.wired) return;
  if (peakQueueingMs < 60) return;
  linkAdvised = true;
  if (!hintEl) return;
  hintEl.textContent =
    `${activeLink.name} is adding about ${peakQueueingMs.toFixed(0)} ms. ` +
    "A cable between the two machines removes it.";
  hintEl.classList.remove("show");
  void hintEl.offsetWidth;
  hintEl.classList.add("show");
}

// ============================================================ Tasks 11.1/11.2
// A settings and connection panel reachable with the mouse, and the screen
// reader support the app never had.

const controlsToggle = document.getElementById("controls-toggle") as HTMLButtonElement;
const panelEl = document.getElementById("panel") as HTMLDivElement;
const panelClose = document.getElementById("panel-close") as HTMLButtonElement;
const connFacts = document.getElementById("conn-facts") as HTMLDListElement;
const connAdvice = document.getElementById("conn-advice") as HTMLParagraphElement;
const disconnectButton = document.getElementById("disconnect") as HTMLButtonElement;
const resSelect = document.getElementById("res-select") as HTMLSelectElement;
const accelSelect = document.getElementById("accel-select") as HTMLSelectElement;
const optHud = document.getElementById("opt-hud") as HTMLInputElement;
const optInput = document.getElementById("opt-input") as HTMLInputElement;
/// Announces a state change to a screen reader.
///
/// Status was written into a plain div, so a blind user was never told that
/// pairing was required, that the connection dropped, or that it recovered.
///
/// The element is looked up on EACH call rather than captured in a module const.
/// setStatus runs during module initialisation, long before the declarations at
/// the bottom of this file are evaluated, so closing over one put it in the
/// temporal dead zone: the first status update threw
/// "Cannot access 'liveRegion' before initialization", which killed the module
/// and with it discovery, connection and the entire interface.
function announce(text: string) {
  const liveRegion = document.getElementById("live");
  if (!liveRegion || !text) return;
  // Cleared first: an identical string written twice is not re-announced.
  liveRegion.textContent = "";
  setTimeout(() => (liveRegion.textContent = text), 30);
}

// --- revealing the control ---------------------------------------------------
let revealTimer: number | undefined;
function revealControls() {
  if (isOverlayVisible()) return; // the connect card has its own controls
  controlsToggle?.classList.add("revealed");
  window.clearTimeout(revealTimer);
  revealTimer = window.setTimeout(() => {
    if (panelEl?.hidden !== false) controlsToggle?.classList.remove("revealed");
  }, 2600);
}
window.addEventListener("mousemove", revealControls);
window.addEventListener("keydown", revealControls);

// --- the panel ---------------------------------------------------------------
let lastFocused: HTMLElement | null = null;

function focusable(): HTMLElement[] {
  return Array.from(
    panelEl.querySelectorAll<HTMLElement>("button, select, input, [href], [tabindex]:not([tabindex='-1'])")
    // Both forms: native `disabled` for the checkboxes, `aria-disabled` for
    // buttons, which stay in the tab order precisely so their tooltip can be
    // reached — but must not be offered as the first thing focused.
  ).filter((el) => !el.hasAttribute("disabled") && el.getAttribute("aria-disabled") !== "true");
}

function openPanel() {
  if (!panelEl) return;
  lastFocused = document.activeElement as HTMLElement | null;
  refreshPanel();
  panelEl.hidden = false;
  controlsToggle?.setAttribute("aria-expanded", "true");
  focusable()[0]?.focus();
  announce("Session settings opened");
}

function closePanel() {
  if (!panelEl || panelEl.hidden) return;
  panelEl.hidden = true;
  controlsToggle?.setAttribute("aria-expanded", "false");
  // Focus must go back where it came from, or a keyboard user is dropped at the
  // top of the document with no idea where they are.
  (lastFocused ?? controlsToggle)?.focus();
}

controlsToggle?.addEventListener("click", () => (panelEl.hidden ? openPanel() : closePanel()));
panelClose?.addEventListener("click", closePanel);
panelEl?.addEventListener("mousedown", (event) => {
  if (event.target === panelEl) closePanel();
});

// A modal that cannot be escaped, or tabbed out of, is a trap rather than a dialog.
panelEl?.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault();
    closePanel();
    return;
  }
  if (event.key !== "Tab") return;
  const items = focusable();
  if (items.length === 0) return;
  const first = items[0];
  const last = items[items.length - 1];
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first.focus();
  }
});

/// Fills the connection facts. Read from the same values the HUD uses, so the
/// two can never disagree.
function refreshPanel() {
  if (!connFacts) return;
  const senderName = localStorage.getItem("ds.senderName") ?? addressInput.value ?? "—";
  const facts: Array<[string, string]> = [
    ["Connected to", senderName],
    ["Link", activeLink
      ? `${activeLink.name}${activeLink.direct ? " · direct" : ""}`
      : "—"],
    ["Delay", `${queueingMs.toFixed(0)} ms`],
    ["Frame rate", `${fps.toFixed(0)} fps`],
    ["Bitrate", `${mbps.toFixed(1)} Mbps`],
    ["Resolution", `${panel.width} × ${panel.height}`],
  ];
  connFacts.replaceChildren(
    ...facts.flatMap(([term, value]) => {
      const dt = document.createElement("dt");
      dt.textContent = term;
      const dd = document.createElement("dd");
      dd.textContent = value;
      return [dt, dd];
    })
  );

  // The cable guidance belongs here, where the user is already looking at the
  // link — not only in a README they will never open.
  if (activeLink && !activeLink.wired && peakQueueingMs >= 40) {
    connAdvice.hidden = false;
    connAdvice.textContent =
      `${activeLink.name} is adding about ${peakQueueingMs.toFixed(0)} ms of delay. ` +
      "A cable between the two machines removes it: Ethernet at both ends, or " +
      "Thunderbolt if both support it. A plain USB-C cable carries no network.";
  } else {
    connAdvice.hidden = true;
  }

  optHud.checked = hudWanted;
  optInput.checked = input.isEnabled;
  accelSelect.value = acceleration;
}

// --- controls that actually do something -------------------------------------
resSelect?.addEventListener("change", () => {
  const value = resSelect.value;
  const [width, height] =
    value === "match" ? [panel.width, panel.height] : value.split("x").map(Number);
  void sendControl({ type: "resize", width, height });
  announce(`Requested ${width} by ${height}`);
});

accelSelect?.addEventListener("change", () => {
  acceleration = accelSelect.value as Acceleration;
  localStorage.setItem("ds.acceleration", acceleration);
  // The decoder is rebuilt on the next keyframe, so ask for one rather than
  // leaving the change to take effect at some unpredictable later moment.
  closeDecoder();
  void sendControl({ type: "request_keyframe" });
  announce(`Decoder set to ${accelSelect.selectedOptions[0].text}`);
});

optHud?.addEventListener("change", () => {
  hudWanted = optHud.checked;
  localStorage.setItem("ds.hud", hudWanted ? "1" : "0");
  hud.classList.toggle("hidden", !hudWanted);
});

optInput?.addEventListener("change", () => {
  input.setEnabled(optInput.checked);
  announce(optInput.checked ? "Sending input to the Mac" : "Input forwarding stopped");
});

disconnectButton?.addEventListener("click", () => {
  closePanel();
  announce("Disconnecting");
  void invoke("disconnect").catch(() => {});
});

// ================================================= Commands 3 and 4 of the audit
// The discovered Mac becomes the primary action, and transport failures become
// something a person can act on.

const heroButton = document.getElementById("connect-hero") as HTMLButtonElement | null;
const manualToggle = document.getElementById("manual-toggle") as HTMLButtonElement | null;
const rescanLink = document.getElementById("rescan-link") as HTMLButtonElement | null;
const failureEl = document.getElementById("failure") as HTMLDivElement | null;
const failureHeadline = document.getElementById("failure-headline") as HTMLDivElement | null;
const failureGuidance = document.getElementById("failure-guidance") as HTMLDivElement | null;
const failureRaw = document.getElementById("failure-raw") as HTMLPreElement | null;
const failureCopy = document.getElementById("failure-copy") as HTMLButtonElement | null;

/// The device the hero button will connect to, chosen by discovery.
let selectedUrl: string | null = null;

export function selectSender(url: string, row?: HTMLElement) {
  selectedUrl = url;
  // The attribute IS the state: styling reads [aria-selected], so what is
  // announced and what is drawn cannot disagree.
  for (const el of document.querySelectorAll(".sender")) {
    el.setAttribute("aria-selected", "false");
  }
  row?.setAttribute("aria-selected", "true");
  if (heroButton) {
    heroButton.hidden = false;
    setEnabled(heroButton, true);
  }
  refreshPrimaryAction();
}

heroButton?.addEventListener("click", () => {
  if (selectedUrl) void connect(selectedUrl);
});

/**
 * Keeps exactly one accent button on the connect screen.
 *
 * The discovered device is the recommended path whenever there is one, so it
 * holds the primary and typing an address is a secondary. With nothing
 * discovered, manual entry IS the path and takes it back.
 */
function refreshPrimaryAction() {
  // Same reason as showManualEntry: reachable from the discovery-failure path
  // during module evaluation, so it must not touch a const declared below it.
  const manualBar = document.getElementById("bar");
  const hero = document.getElementById("connect-hero");
  const heroShowing = hero !== null && !(hero as HTMLElement & { hidden: boolean }).hidden;
  const manualShowing = manualBar !== null && !manualBar.hidden;
  setVariant(
    document.getElementById("connect"),
    heroShowing && manualShowing ? "secondary" : "primary"
  );
}

refreshPrimaryAction();

// Enter connects, so the common case needs no mouse at all.
window.addEventListener("keydown", (event) => {
  if (event.key !== "Enter") return;
  if (!isOverlayVisible()) return;
  const target = event.target as HTMLElement | null;
  // Let the PIN and address fields keep their own Enter behaviour.
  if (target && ["INPUT", "TEXTAREA"].includes(target.tagName)) return;
  if (selectedUrl && heroButton && !heroButton.hidden) {
    event.preventDefault();
    void connect(selectedUrl);
  }
});

/**
 * Reveals or hides manual address entry.
 *
 * Shared with the discovery-failure path: when the network cannot be searched,
 * the only way forward is to type an address, and leaving it folded away behind
 * a disclosure makes a dead end out of a recoverable state.
 */
export function showManualEntry(show: boolean, focus = true) {
  // Elements are resolved HERE rather than closed over from module-level
  // consts. Discovery can fail during module evaluation, before those consts
  // are initialised, and reading one in its temporal dead zone throws a
  // ReferenceError — which is exactly how v0.9.0 bricked itself.
  const bar = document.getElementById("bar");
  const toggle = document.getElementById("manual-toggle");
  if (!bar || !toggle) return;
  bar.hidden = !show;
  toggle.setAttribute("aria-expanded", String(show));
  refreshPrimaryAction();
  if (show && focus) {
    (document.getElementById("address") as HTMLInputElement | null)?.focus();
  }
}

manualToggle?.addEventListener("click", () => {
  const bar = document.getElementById("bar");
  showManualEntry(bar?.hidden ?? true);
});

rescanLink?.addEventListener("click", () => void scanForSenders());

failureCopy?.addEventListener("click", () => {
  void navigator.clipboard?.writeText(failureRaw?.textContent ?? "");
  failureCopy.textContent = "Copied";
  setTimeout(() => (failureCopy.textContent = "Copy"), 1500);
});

/// Shows a failure the user can act on, keeping the raw text behind a
/// disclosure because bug reports still need it.
export function showFailure(raw: string, terminal: boolean) {
  const friendly = humanise(raw);
  if (!failureEl || !failureHeadline || !failureGuidance || !failureRaw) return;
  failureHeadline.textContent = friendly.headline;
  failureGuidance.textContent = friendly.guidance;
  failureRaw.textContent = friendly.detail;
  failureEl.classList.toggle("terminal", terminal || friendly.terminal);
  failureEl.hidden = false;
  // Announced as well as shown, or a screen reader user learns nothing.
  announce(`${friendly.headline}. ${friendly.guidance}`);
}

export function clearFailure() {
  if (failureEl) failureEl.hidden = true;
}

// ------------------------------------------------------------- Command 8
// The states that are not the happy path. The audit scored this category 0/6,
// and the connect screen is mostly not the happy path — waiting, retrying and
// failing all live here.

const connectingEl = document.getElementById("connecting") as HTMLDivElement | null;
const connectingLabelEl = document.getElementById("connecting-label") as HTMLSpanElement | null;
const emptyStateEl = document.getElementById("empty-state") as HTMLDivElement | null;

/// Names of discovered senders, so a connection can be described by machine
/// rather than by socket. Keyed by the URL the app dials.
const senderNames = new Map<string, string>();

/// What to call the thing we are connecting to.
///
/// Never the URL. "Connecting to ws://192.168.29.8:8788…" tells the reader the
/// transport and the port and nothing they can act on, which is the same failure
/// as the raw error strings this project already removed.
export function connectingLabel(url: string): string {
  const known = senderNames.get(url);
  if (known) return known;
  // Fall back to the host alone — still no scheme, still no port.
  try {
    return new URL(url).hostname;
  } catch {
    return "your Mac";
  }
}

function showConnecting(name: string) {
  showEmptyState(false);
  clearFailure();
  if (!connectingEl || !connectingLabelEl) return;
  // The attempt count appears only once retrying has clearly failed twice —
  // showing "Attempt 1 of 4" immediately makes a normal connection look sickly.
  const suffix = attempt >= 2 ? ` · attempt ${attempt + 1} of ${RETRY_LIMIT}` : "";
  connectingLabelEl.textContent = `Connecting to ${name}…${suffix}`;
  connectingEl.hidden = false;
  setStatus("");
  announce(`Connecting to ${name}`);
}

function hideConnecting() {
  if (connectingEl) connectingEl.hidden = true;
}

function showEmptyState(visible: boolean) {
  if (!emptyStateEl) return;
  emptyStateEl.hidden = !visible;
  if (visible) {
    hideConnecting();
    setStatus("");
    announce("No Macs found on this network");
  }
}
