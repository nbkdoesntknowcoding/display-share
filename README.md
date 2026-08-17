# Display Share

Use a Windows laptop as a genuine extended second display for a Mac.

A laptop's HDMI port is output-only, so no cable can do this. Display Share
creates a **real virtual display** on the Mac — macOS believes a monitor is
attached — captures it, encodes it in hardware, and streams it to the receiver
over the LAN.

> **Status: in development.** Phases 0–2 are complete: the Mac sender creates a
> virtual display, captures it, encodes H.264 and serves it over WebSocket, with
> a browser test client. The Windows receiver (Phase 3) is not built yet.

---

## Current state

| Phase | Scope | Status |
|---|---|---|
| 0 | Feasibility spike | ✅ complete |
| 1 | Mac sender MVP (MJPEG) | ✅ complete |
| 2 | H.264 pipeline | ✅ complete |
| 3 | Windows receiver (Tauri) | ✅ complete (`.exe` needs a Windows host) |
| 4 | Session robustness | not started |
| 5 | Input injection | not started |
| 6 | Packaging & signing | not started |
| 7 | VPS, updates & release | not started |

---

## Running it today

```bash
cd mac && xcodegen generate && xcodebuild -scheme DisplayShare -configuration Debug -derivedDataPath ./.build build
```

Launch `DisplayShare.app`, click **Start** in the menu bar, then open the URL it
shows. Endpoints:

| URL | What |
|---|---|
| `http://<mac>:8787/` | H.264 WebCodecs test client |
| `http://<mac>:8787/mjpeg` | Phase 1 MJPEG client, for comparison |
| `ws://<mac>:8788` | the actual protocol ([`protocol/SPEC.md`](protocol/SPEC.md)) |

---

## Two things that will bite you

### 1. WebCodecs needs a secure context

`VideoDecoder` is only available in a **secure context**. That means:

* `http://localhost` — **works** (localhost is treated as secure)
* `http://192.168.x.x` — **does not work**; the browser disables WebCodecs
* `https://…` — works, but needs a certificate the receiver trusts

So the browser test client is usable **on the Mac itself**, and over the LAN it
needs either HTTPS with a self-signed certificate the receiver trusts, or a
localhost proxy on the receiver. The page detects this and says so rather than
silently showing black.

This constraint disappears in Phase 3: the Tauri receiver owns the WebSocket in
its Rust backend and hands frames to the webview, so no secure context is
required.

### 2. Chrome's hardware H.264 decoder is *much* slower than software

Measured on macOS 26.2 at 1080p60, one-way sender→paint latency:

| Decode path | Median | Range | Bandwidth |
|---|---:|---:|---:|
| H.264, `prefer-hardware` | **69.1 ms** | 22–75 ms | 1.34 Mbps |
| MJPEG | 7.4 ms | 4.5–21.5 ms | 20.4 Mbps |
| H.264, `prefer-software` | **3.1 ms** | 1.6–5.6 ms | 1.32 Mbps |

The hardware decoder carries a deep pipeline that costs ~22× the latency of
software decoding the identical stream. Since latency is the whole point of this
product, the client defaults to `hardwareAcceleration: 'prefer-software'`.
Override with `?hw=hardware` to compare.

**Caveat:** measured decoding on an M4 Mac. Software decode costs CPU, and the
trade-off on the receiver's own hardware may differ — Phase 3 re-measures on the
actual Windows laptop before this default is final.

---

## Known limits

These come from the private `CGVirtualDisplay` API and are not going away:

* **60 Hz ceiling.** Every mode the virtual display advertises is 60 Hz.
* **Reliable up to about 1920x1200.** Larger geometries misbehave *silently*:
  2560x1080 is adopted as 1280x540 and 2560x1440 as 1920x1080, while
  `applySettings:` still reports success. Display Share therefore fits the
  receiver's **aspect ratio** inside the reliable envelope (a 2560x1080 panel
  becomes 1920x810, filling it exactly) and reads the adopted geometry back
  instead of trusting the API.
* **SDR only.** No HDR.
* **No HDCP**, so DRM-protected video will not play on the virtual display.
* **Not on the Mac App Store.** `CGVirtualDisplay` is a private API, so
  distribution is direct download only.
* **macOS 14+.**

Network: 5 GHz Wi-Fi or Ethernet. 2.4 GHz jitter is visible.

---

## Permissions

Display Share needs **Screen Recording** permission to capture the display it
creates. It captures *only* its own virtual display, never your main screen —
but macOS makes no such distinction, so the standard purple recording indicator
appears, exactly as it does for Zoom or OBS.

A freshly built copy has its own TCC identity, so the permission must be granted
to that specific copy. Rebuilding to a new path means granting again.

---

## Repository layout

```
windows/
  src/                TypeScript frontend: WebCodecs decode + canvas
  src-tauri/          Rust backend: owns the WebSocket
  scripts/            golden-vector verification
mac/
  DisplayShare/       SwiftUI MenuBarExtra app
  DisplayShareCore/   capture, encode, transport
  vd_helper/          subprocess that owns the CGVirtualDisplay
  Shared/             wire protocol + helper IPC, compiled into both
  spike/              Phase 0 throwaway spike (vdspike)
  dsprobe/            dev harness for capture/encode measurements
  scripts/            acceptance tests
protocol/             SPEC.md + golden test vectors
docs/                 findings
```

`vd_helper` is a separate process on purpose: the virtual display dies with the
process holding it, so isolating it means a crash in the capture or encode
pipeline does not destroy the user's window arrangement. If the app crashes, the
helper holds the display for a grace period so a relaunched app re-attaches to
the *same* display.

---

## Development notes

The Xcode project is generated from [`mac/project.yml`](mac/project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — edit the YAML, not the
`.xcodeproj`.

```bash
brew install xcodegen
cd mac && xcodegen generate

# unit tests
xcodebuild -scheme DisplayShareCore -derivedDataPath ./.build test

# acceptance
./scripts/test-helper-lifecycle.sh      # vd_helper lifecycle
python3 scripts/ws-acceptance.py        # wire protocol over WebSocket

# receiver
cd ../windows && npm install
node scripts/verify-vectors.mjs         # TS parser vs the same golden vectors
npx tauri dev                           # run the receiver
```

### Building the Windows `.exe`

`npx tauri build` produces a bundle for the **host** platform. On macOS it emits
a `.app`; asking for `--bundles nsis` there compiles the binary and then
silently produces no installer, which is easy to mistake for success. The NSIS
`.exe` requires a Windows host or a `windows-latest` CI runner — wired up in
Task 7.1.

## Licensing

Built on [DeskPad](https://github.com/Stengo/DeskPad) (MIT) as the reference for
the virtual-display approach. The private CoreGraphics interface in
`mac/CGVirtualDisplayPrivate` was derived by Objective-C runtime introspection
on the target machine, not copied. GPL-3.0 projects in this space (opendisplay,
Lumen, Sunshine, moonlight-qt) were read for architecture only; no source was
copied from them.
