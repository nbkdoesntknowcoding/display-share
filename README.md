# Display Share

Use a Windows laptop as a genuine extended second display for a Mac.

A laptop's HDMI port is output-only, so no cable can do this. Display Share
creates a **real virtual display** on the Mac — macOS believes a monitor is
attached — captures it, encodes it in hardware, and streams it to the receiver
over the LAN.

> **Status: in development.** Phases 0–5 are complete: the Mac sender creates a
> virtual display, captures it, encodes H.264 and serves it over WebSocket, and
> the Tauri receiver decodes and paints it while negotiating its own panel
> geometry. Sessions are discovered over Bonjour, paired with a PIN, and survive
> network drops, sleep/wake and display reconfiguration, with adaptive bitrate.
> Mouse and keyboard can drive the Mac from the receiver. The receiver has been
> verified as a running app; producing the Windows `.exe` still needs a Windows
> host or CI (see below).

---

## Current state

| Phase | Scope | Status |
|---|---|---|
| 0 | Feasibility spike | ✅ complete |
| 1 | Mac sender MVP (MJPEG) | ✅ complete |
| 2 | H.264 pipeline | ✅ complete |
| 3 | Windows receiver (Tauri) | ✅ complete (`.exe` needs a Windows host) |
| 4 | Session robustness | ✅ complete |
| 5 | Input injection | ✅ complete |
| 6 | Packaging | ✅ pipeline done; ships unsigned by design |
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

This constraint does not apply to the Tauri receiver: its Rust backend owns the
WebSocket and hands frames to the webview, which only ever sees
`tauri://localhost`. No certificate is needed on the LAN.

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

**Caveat:** measured in Chromium on an M4 Mac. Two reasons this is not settled
for the shipping receiver: software decode costs CPU and a low-power laptop may
invert the trade-off, and Tauri uses **WKWebView on macOS but WebView2
(Chromium) on Windows** — so only a run on the actual Vivobook decides it. The
receiver cycles the setting with the `A` key so it can be measured there.

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

## Pairing

The sender advertises itself over Bonjour (`_displayshare._tcp`), so the receiver
finds it without an IP being typed in. A new receiver is shown a 4-digit PIN on
the Mac; entering it issues a token the receiver stores, making later connections
one click.

A 4-digit PIN is only 10,000 possibilities, so the real protection is **rate
limiting**: three attempts per minute per device, applied to correct PINs too
while active. Tokens are 32 random bytes, stored only as a SHA-256 hash,
compared in constant time, and bound to the device that earned them. An unpaired
receiver gets **no video at all** — authorisation is checked both at the encode
gate and inside the send path.

Manage or revoke paired devices by deleting
`~/Library/Application Support/DisplayShare/paired-devices.json`.

---

## Installing

There is no signed release yet. `mac/scripts/package-macos.sh` produces a
universal `.dmg`, but **without an Apple Developer ID certificate it is unsigned**,
so macOS will warn on first open. The script says so explicitly rather than
handing you a DMG that looks shippable:

```bash
cd mac && ./scripts/package-macos.sh
```

```
universal:  yes (arm64 + x86_64)
signed:     NO — ad-hoc only
notarized:  NO
```

Display Share is open source and ships **unsigned by decision** — see
[docs/distribution.md](docs/distribution.md) for exactly what each OS warns and
what to click, plus how building from source avoids the warning entirely.

---

## Remote control

Press **F8** on the receiver to forward mouse and keyboard to the Mac; a badge
across the top shows when it is live, and F8 releases it. Losing window focus
releases every held key, so a modifier cannot get stuck down on the Mac.

This needs **Accessibility** permission in addition to Screen Recording — macOS
silently discards synthetic events without it, so Display Share tells the
receiver `input_unavailable` rather than accepting input and appearing to do
nothing. The menu bar offers a direct link to the right Settings pane.

Input is refused from any receiver that has not paired, checked at the socket
boundary: driving the Mac is a far stronger capability than viewing it.

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
python3 scripts/pairing-acceptance.py   # discovery + PIN pairing
python3 scripts/robustness-soak.py      # drops, reconfiguration, recovery
python3 scripts/abr-acceptance.py       # adaptive bitrate
python3 scripts/input-acceptance.py     # input forwarding + auth gate
python3 scripts/injection-acceptance.py # CGEvent injection vs the real cursor

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
