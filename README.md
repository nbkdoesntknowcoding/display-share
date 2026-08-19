# Display Share

**Use a Windows laptop as a genuine extended second display for a Mac.**

A laptop's HDMI port is output-only, so no cable can do this. Display Share
creates a **real virtual display** on the Mac — macOS believes a monitor is
attached, and you can drag windows onto it, set its resolution, and arrange it in
System Settings. It then captures that display, encodes it in hardware, and
streams it over your LAN to a receiver app on the laptop.

> **Status: working end to end.** Verified on 18 Aug 2026: a Mac mini streaming
> to a Windows laptop over the LAN, video confirmed on real Windows hardware.
> Phases 0–7 of the build plan are implemented. Remaining gaps are listed under
> [What isn't proven yet](#what-isnt-proven-yet).

```
   Mac mini                                      Windows laptop
 ┌───────────────────────┐                     ┌──────────────────────┐
 │ CGVirtualDisplay      │                     │  Tauri receiver      │
 │   ↓ ScreenCaptureKit  │   H.264 over        │   ↓ WebCodecs        │
 │   ↓ VideoToolbox      │ ──WebSocket (LAN)──▶│   ↓ canvas           │
 │   ↑ CGEvent injection │ ◀──input events──── │   ↑ mouse + keyboard │
 └───────────────────────┘                     └──────────────────────┘
```

---

## Two apps, and which one you need

Display Share is a pair. Installing or opening the wrong half is the most
likely way to get confused, so:

| | Runs on | What it looks like | You want it if |
|---|---|---|---|
| **DisplayShare** (sender) | the **Mac** | a **menu bar icon** — no Dock icon, no window | you want an extra screen |
| **Display Share Receiver** | the **laptop** | a fullscreen window | it is the screen being borrowed |

The sender showing "no window" is not a failure — it is a menu bar app. Look at
the top-right of the screen for a display icon.

If you see **"Enter the Mac's address and press Connect"**, you have opened the
*receiver* on the Mac. That is the wrong half; close it and open the sender.

---

## Installing

### The one-command way (recommended)

```bash
git clone https://github.com/nbkdoesntknowcoding/display-share.git
cd display-share && ./install.sh
```

That checks your macOS version and tools, installs `xcodegen` if missing, builds,
installs to `/Applications`, and opens the right Settings pane. `./install.sh
--uninstall` reverses it.

**Building is the *easy* path here, not the hard one.** A locally built app has no
quarantine attribute, so macOS launches it normally — no "Apple cannot check it
for malicious software", no trip through Privacy & Security to click *Open
Anyway*. Downloading the `.dmg` is the route that triggers that warning, because
Display Share is open source and does not buy code signing certificates.

### Or ask your coding agent

Paste this into Claude Code, Cursor, or any agent with shell access:

````text
Set up Display Share on this machine. It turns a Windows laptop into a real
second display for a Mac. Repo: https://github.com/nbkdoesntknowcoding/display-share

MAC SENDER (only runs on macOS 14+):
1. git clone https://github.com/nbkdoesntknowcoding/display-share.git && cd display-share
2. Run ./install.sh and show me its output. It installs xcodegen if needed,
   builds a Release build, and installs to /Applications.
3. If it fails, read the build log path it prints and fix or report the error.
   Do NOT skip failures or fall back to a Debug build.

THEN STOP AND ASK ME. You cannot do the next part:
macOS permissions are granted by a human in System Settings — no command,
script, or API can grant them, and a freshly built copy counts as a NEW app
identity even if I granted them before. Tell me to:
  - System Settings > Privacy & Security > Screen Recording > enable Display Share
  - (only if I want to control the Mac from the laptop)
    Privacy & Security > Accessibility > enable Display Share
Then wait for me to confirm.

VERIFY (after I confirm):
4. Launch /Applications/DisplayShare.app. It is a MENU BAR app — no Dock icon,
   no window. Click its icon and press Start.
5. Confirm a virtual display exists: `system_profiler SPDisplaysDataType | grep -i display`
   should show one more display than the physical monitors.
6. Open http://localhost:8787 in a browser on the Mac. Expect a black canvas and
   a HUD. It stays black until something is actually on that display — drag a
   window onto the new display, then the HUD should show ~58 fps.
   A near-black screen with capture near 0 fps is CORRECT for an empty desktop
   (a few fps still trickle in from the menu bar clock) — that is not a bug.

WINDOWS RECEIVER (run this part on the Windows laptop):
7. Install Rust (https://rustup.rs) and Node 22+.
8. cd windows && npm ci && npx tauri build
9. Run the installer from windows/src-tauri/target/release/bundle/nsis/
   SmartScreen will warn because it is unsigned: More info > Run anyway.
10. The app finds the Mac over Bonjour. Enter the 4-digit PIN the Mac shows.
    Both machines must be on the same network, on 5 GHz Wi-Fi or Ethernet.

USEFUL TO KNOW:
- Ports 8787 (viewer page) and 8788 (video + control) must not be blocked.
- Keys in the receiver: F11 fullscreen, F8 forward input to the Mac, H toggle
  HUD, A cycle decode mode.
- Read README.md "Known limits" before reporting a bug — the 60 Hz cap, the
  ~1920x1200 geometry ceiling and no-HDCP are properties of Apple's private
  API, not defects.
- If anything is ambiguous, read docs/distribution.md and protocol/SPEC.md
  rather than guessing.
````

### Or download a build

[Latest release](https://github.com/nbkdoesntknowcoding/display-share/releases/latest)
— universal `.dmg` for the Mac, NSIS `.exe` for Windows, with `SHA256SUMS`.

These are **unsigned**, so both systems warn on first launch:

* **macOS** — open it once, then System Settings → Privacy & Security → **Open Anyway**
* **Windows** — **More info** → **Run anyway**

[docs/distribution.md](docs/distribution.md) explains why, and what each warning
actually means.

### Manual build

```bash
# Mac sender
brew install xcodegen
cd mac && xcodegen generate
xcodebuild -scheme DisplayShare -configuration Release -derivedDataPath ./.build build

# Windows receiver (needs Rust + Node 22)
cd windows && npm ci && npx tauri build
```

---

## Using it

1. Launch **Display Share** on the Mac (`./install.sh` puts it in
   `/Applications` and launches it). First run explains the one permission it
   needs and detects the grant without a restart.
2. Click **Start** in the menu bar.
3. Launch the receiver on the laptop. It finds the Mac over Bonjour — no IP
   address to type.
4. Enter the 4-digit PIN shown on the Mac. This happens once per device.
5. Press **F11** for fullscreen. Drag windows onto the new display.

**Two directions of control, and they are not the same thing:**

* **Your Mac's own mouse and keyboard already work on the second screen** — it is
  a real display, so the cursor walks onto it exactly like a physical monitor.
  Nothing to enable.
* **To drive the Mac from the laptop's keyboard and trackpad**, press **F8** on
  the receiver. A badge shows while it is live; F8 again releases it. This needs
  **Accessibility** permission on the Mac — without it macOS silently discards
  injected events, so the app reports `input_unavailable` rather than pretending
  to work.
* **Push the cursor past the edge** of the second screen and it keeps going onto
  the rest of the Mac's desktop. The receiver takes a pointer lock and switches
  to relative motion at that point, because the OS clamps the real pointer at the
  screen edge and an absolute position simply pins at the boundary. Move back
  onto the second screen and control returns automatically. F8, or Esc, hands the
  pointer back at any time.

Controlling *Windows applications* from the Mac is **not** in this version. It is
planned as Phase 8: capturing the real Windows desktop and viewing it on the Mac,
which needs no display driver and no certificate. The mirror image — making the
Mac a second display *for* Windows — would need a signed Windows Indirect Display
Driver, so it is deliberately not planned.

### Viewing Windows from the Mac

The reverse direction is a **remote desktop**, not a second display. One install
on each machine does both; you pick a direction rather than reinstalling.

1. **Windows** — open Display Share Receiver and click **Share this PC's screen
   instead**. It shows the machine name and port.
2. **Mac** — menu bar icon → **View a Windows PC…**. It finds the PC on its own;
   if mDNS is blocked, type the address and port `7879`.

**Only one direction runs at a time.** Both apps refuse the second one rather
than trusting you not to try it: two machines each capturing and encoding the
other feeds each screen back into the other, saturating the link, and the
adaptive bitrate controller assumes a single stream — so it would react to
congestion it was itself creating.

### Controlling Windows from the Mac

Click **Control this PC** in the viewer window. Your mouse and keyboard then
drive Windows while the window has focus; click it again to stop. A green badge
shows while it is on, because forwarding the keyboard is a strong capability and
should never be ambiguous.

Windows needs no permission for this — there is no equivalent of macOS's
Accessibility prompt. It does refuse to inject into **windows running as
administrator**: Task Manager, an elevated PowerShell, and the UAC prompt itself
will ignore the Mac's keyboard while everything else keeps working. That is a
deliberate Windows security boundary, not a fault in Display Share. If you need
it, run the receiver as administrator too.

Keys are sent by physical position rather than by the character they produce, so
a UK Mac driving a US Windows machine types what you actually pressed.

### Turning the mirror into a real extra desktop

By default this duplicates the Windows screen, so the Mac shows whatever the
Windows monitor shows. Windows cannot be given a *virtual* display without an
Indirect Display Driver, and that needs a signed driver — see above.

A **dummy display adapter** (an HDMI or DisplayPort plug that reports a monitor,
roughly the price of a coffee) sidesteps this entirely. Windows genuinely
extends onto it, and the display picker next to the share button lets you share
*that* output instead. The Windows laptop keeps its own screen, and the Mac shows
a separate desktop. No driver, no certificate.

> Unverified: this has not been tried with a real adapter yet. The code path is
> exercised, the hardware is not.

---

## Using a cable instead of Wi-Fi

Wi-Fi is usually the largest source of lag, and not because of bandwidth — a
1080p stream needs roughly 10-15 Mbps, which any modern link manages. It is
**jitter**: frames arrive in clumps, and a clump is felt as a stutter even when
the average frame rate looks perfect. A cable removes it, and costs nothing in
sharpness or frame rate.

The apps need no configuration for this. Display Share runs over whatever IP link
exists, and both ends advertise and browse on every interface, so plugging in a
cable is the entire procedure.

**The HUD names the link it is actually using** — `Ethernet`, `Wi-Fi`, and
`direct` when the two machines are wired straight to each other. If the link is
wireless and measurably costing time, the receiver says so once, with the number.

### Which cable

| Setup | Works | Notes |
|---|---|---|
| Ethernet, both into the router | Yes | Simplest. Removes Wi-Fi from both ends. |
| Ethernet, machine to machine | Yes | Lowest latency. Modern ports auto-negotiate, so no crossover cable is needed. |
| Thunderbolt / USB4, machine to machine | Yes, if **both** ends support it | macOS calls this Thunderbolt Bridge. Very fast. |
| A plain USB-C cable | **No** | USB-C is a connector, not a network. Without Thunderbolt on both ends it carries no IP at all. |

> **Check before buying anything.** On Windows, look for a *Thunderbolt* controller
> in Device Manager. Many laptops have USB-C ports that do power and DisplayPort
> but not Thunderbolt, and those cannot bridge. If yours is one of them, two
> USB-C-to-Ethernet adapters and a cable achieve the same result for very little.

### Wiring the two machines directly

With no router in between, neither machine gets an address from DHCP, so both
self-assign one in `169.254.x.x`. This is normal and needs no setup — discovery
works over it, and the HUD shows `direct` when it happens.

The Mac keeps its normal Wi-Fi connection at the same time, so the internet
carries on working; the cable is used only for the machine-to-machine traffic.

---

## Requirements

| | |
|---|---|
| Mac | macOS 14 or later, Apple Silicon or Intel |
| Receiver | Windows 10/11. Any device with a modern browser also works for testing |
| Network | **5 GHz Wi-Fi or Ethernet.** 2.4 GHz jitter is visible as stutter |
| Permissions | Screen Recording (required), Accessibility (only for remote control) |

---

## Known limits

These come from the private `CGVirtualDisplay` API and are **not** going away:

| Limit | Detail |
|---|---|
| **60 Hz ceiling** | Every mode the virtual display advertises is 60 Hz. Requesting 120 yields ~64 fps because the surface does not update faster |
| **~1920×1200 maximum** | Larger geometries are adopted *wrongly* and silently: 2560×1080 becomes 1280×540, 2560×1440 falls back to 1920×1080. Display Share fits your panel's **aspect ratio** inside the reliable envelope instead — a 2560×1080 panel gets 1920×810, which fills it exactly with no letterboxing |
| **SDR only** | No HDR |
| **No HDCP** | DRM-protected video (Netflix, Apple TV+) will not play on the virtual display |
| **Not on the Mac App Store** | `CGVirtualDisplay` is a private API; App Review rejects private API use outright |
| **Private API risk** | A future macOS release could remove or change `CGVirtualDisplay`. Verified working on macOS 26.2 (25C56) |

---

## Performance

Measured on a Mac mini M4, macOS 26.2, at 1080p60 over **localhost** — so these
exclude LAN transit and are a floor, not a promise:

| | Value |
|---|---|
| Capture | 57.8 fps (against a 60 fps target) |
| H.264 encode | 5.62 ms/frame |
| Bandwidth | ~1.4 Mbps synthetic content; ~20 Mbps for the MJPEG fallback |
| Capture cost | ~1.4% of one core |
| Decode (software) | ~3 ms |

**On latency, deliberately not a headline number.** One-way sender→paint measured
**3.1 ms median** in Chromium with software decode on the same machine. That
figure excludes network transit entirely and was measured in a browser, not in
the shipping receiver. Real end-to-end latency on a LAN will be higher, and has
not been measured on real hardware yet.

One finding worth knowing: Chrome's **hardware** H.264 decoder carries a ~69 ms
pipeline, **22× worse** than software decoding the identical stream. The receiver
defaults to software decode because of this. Press **A** on the receiver to cycle
the setting and measure it on your own hardware.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Cannot be opened because Apple cannot check it" | Unsigned build | System Settings → Privacy & Security → **Open Anyway**. See [docs/distribution.md](docs/distribution.md) |
| "Windows protected your PC" | Unsigned installer | **More info** → **Run anyway** |
| Menu bar says *Screen Recording permission has not been granted* | macOS TCC | Grant it, then reopen the menu. A freshly built copy is a new identity and needs granting again |
| **Settings shows Display Share enabled, but the app still asks for permission** | The listed entry belongs to an **older build**. macOS lists apps by name, so a stale entry is indistinguishable from a live one | `install.sh` now signs with a stable local identity, so this should not recur. If you hit it on an older copy: `tccutil reset ScreenCapture in.theboringpeople.displayshare`, then grant again |
| App says *Not granted* even though you just granted it | `CGPreflightScreenCaptureAccess()` caches its answer for the life of the process, so an app that was already running cannot see a new grant | The app now detects this via a short-lived child process and shows **"Granted — restart"**. Quit and reopen it |
| Receiver shows black, HUD says `capture 0.0 fps` | Nothing is on the virtual display | Drag a window onto it. An idle desktop legitimately sends no frames |
| Receiver cannot find the Mac | mDNS blocked, or different subnets | Type the Mac's IP manually in the receiver. Guest and AP-isolated Wi-Fi block Bonjour |
| `busy — another receiver is already connected` | One receiver at a time, by design | Close the other receiver, or wait ~10 s for the socket to drop |
| Stutter, image goes soft under load | Adaptive bitrate reducing quality | Working as designed: sharpness degrades rather than latency accumulating. Move to 5 GHz or Ethernet |
| Mouse and keyboard do nothing after pressing F8 | **Accessibility** not granted — it is a SEPARATE permission from Screen Recording, so video can work perfectly while input is blocked | Enable Display Share under Privacy & Security → Accessibility. To check what the app actually sees: `open -a /Applications/DisplayShare.app --args --check-permissions --out /tmp/p.txt && sleep 3 && cat /tmp/p.txt` |
| Windows scattered after a crash | The display was destroyed | Relaunch within ~8 s and the helper re-attaches the *same* display, preserving arrangement |
| Second display gone after Mac sleep | Capture died on wake | Recovers automatically, typically under 0.1 s. If not, toggle Stop then Start |
| Opened the app on the Mac and got "Enter the Mac's address and press Connect" | That is the **receiver**, not the sender | Close it. The sender is `DisplayShare.app` and appears only in the **menu bar** |
| Launched the sender and nothing happened | It is a menu bar app — `LSUIElement`, so no Dock icon and no window by design | Look at the top-right menu bar for a display icon and click it |

---

## Updates

Both apps check GitHub Releases at launch. **Neither updates silently** — the
Mac app links you to the release page, and the Windows app downloads only after
you click *Update and restart*. For an unsigned app, a self-replacing binary is
the wrong default. See [docs/distribution.md](docs/distribution.md#updates) for
the rollback path.

---

## Privacy

Display Share captures **only the virtual display it creates**, never your real
screen. macOS makes no such distinction, so the purple recording indicator
appears exactly as it does for Zoom or OBS.

Video never leaves your LAN — there is no server, no account, no telemetry. A
receiver must pair with a 4-digit PIN before it gets any video, and input
forwarding is refused entirely until it does.

---

## Repository layout

```
install.sh            one-command build + install for the Mac sender
mac/
  DisplayShare/       SwiftUI MenuBarExtra app + onboarding
  DisplayShareCore/   capture, encode, transport, pairing, input
  vd_helper/          subprocess that owns the CGVirtualDisplay
  Shared/             wire protocol + helper IPC, compiled into both
  spike/              Phase 0 throwaway spike (vdspike)
  dsprobe/            dev harness for capture/encode measurements
  scripts/            acceptance tests + packaging
windows/
  src/                TypeScript frontend: WebCodecs decode + canvas + input
  src-tauri/          Rust backend: owns the WebSocket
protocol/             SPEC.md + golden test vectors
docs/                 findings, distribution
```

`vd_helper` is a separate process on purpose: a virtual display dies with the
process holding it, so isolating it means a crash in the capture or encode
pipeline does not destroy your window arrangement.

---

## Development

```bash
brew install xcodegen
cd mac && xcodegen generate

xcodebuild -scheme DisplayShareCore -derivedDataPath ./.build test   # 50 unit tests

./scripts/test-helper-lifecycle.sh      # vd_helper lifecycle
python3 scripts/ws-acceptance.py        # wire protocol over WebSocket
python3 scripts/pairing-acceptance.py   # discovery + PIN pairing
python3 scripts/robustness-soak.py      # drops, reconfiguration, recovery
python3 scripts/abr-acceptance.py       # adaptive bitrate
python3 scripts/input-acceptance.py     # input forwarding + auth gate
python3 scripts/injection-acceptance.py # CGEvent injection vs the real cursor

cd ../windows && npm ci
node scripts/verify-vectors.mjs         # TS parser vs the same golden vectors
npx tauri dev
```

The Xcode project is generated from [`mac/project.yml`](mac/project.yml) — edit
the YAML, not the `.xcodeproj`. The wire protocol is specified in
[`protocol/SPEC.md`](protocol/SPEC.md), and the Swift and TypeScript parsers are
tested independently against the same golden vectors so a shared misunderstanding
cannot pass.

---

## What isn't proven yet

Stated plainly, because everything above was measured but these were not:

* **Latency on Windows is unmeasured.** Video is confirmed working there, but no
  one has recorded the numbers on WebView2 — press `H` for the HUD and `A` to
  compare software against hardware decode.
* **Cursor roaming past the screen edge is unverified.** The clamping is covered
  by tests, but the pointer-lock handoff has only been reasoned about, not used.
* **Latency over a real LAN is unmeasured.** All figures above are localhost.
* **No real sleep/wake cycle.** The recovery path was exercised through the same
  entry point the wake notification calls, not by actually sleeping the Mac.
* **2.4 GHz congestion** was simulated through the control channel, not real RF.

---

## Licence

GPL-3.0. See [LICENSE](LICENSE).

Built with reference to [DeskPad](https://github.com/Stengo/DeskPad) (MIT) for
the virtual-display approach. The private CoreGraphics interface in
`mac/CGVirtualDisplayPrivate` was derived by Objective-C runtime introspection on
the target machine, not copied from any project. GPL-3.0 projects in this space
(opendisplay, Lumen, Sunshine, moonlight-qt) were read for architecture only.
