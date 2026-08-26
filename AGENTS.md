# Working in this repository

Notes for coding agents. [CONTRIBUTING.md](CONTRIBUTING.md) covers the licensing
rules; this covers how to build, what to run, and the specific ways this codebase
will mislead you if you assume the usual conventions.

## The shape of it

Two applications that talk over a documented wire protocol.

| Path | What it is |
|---|---|
| `mac/DisplayShare/` | SwiftUI menu bar app — no window, `LSUIElement` |
| `mac/DisplayShareCore/` | capture, encode, transport, pairing, input. Most logic lives here |
| `mac/vd_helper/` | separate process that owns the `CGVirtualDisplay` |
| `mac/Shared/` | wire protocol and helper IPC, compiled into both |
| `windows/src/` | TypeScript frontend: WebCodecs decode, canvas, input |
| `windows/src-tauri/` | Rust backend that owns the WebSocket |
| `protocol/` | `SPEC.md` and golden vectors |

## Four things that will catch you out

**The Xcode project is generated.** Edit `mac/project.yml`, then run
`xcodegen generate`. Changes made directly to `DisplayShare.xcodeproj` are
overwritten, including new files — a test file added only to the `.xcodeproj`
silently never runs.

**The protocol has golden vectors.** The Swift and TypeScript parsers are each
tested against the same bytes in `protocol/vectors/`, never against each other,
so a shared misunderstanding cannot pass. Changing the wire format means
revising `protocol/SPEC.md` and both implementations. Do not add a field to the
header for convenience.

**macOS permissions cannot be granted by a script.** Screen Recording and
Accessibility are granted by a human in System Settings, and a freshly built
copy is a *new identity* even if permission was granted to a previous build. If
a task needs them, stop and ask. There is no API, entitlement or `sudo` that
does it.

**`mac/build/` is hundreds of megabytes** and must never be committed. It is
ignored; do not add it back with `git add -f`.

## Commands

```bash
# Mac
brew install xcodegen
cd mac && xcodegen generate
xcodebuild -scheme DisplayShareCore -derivedDataPath ./.build test

# Windows receiver — the Rust half builds and tests on macOS too
cd windows && npm ci
cargo test --manifest-path src-tauri/Cargo.toml
npm run build

# Frontend checks, all run in CI
node scripts/verify-vectors.mjs
node --experimental-strip-types scripts/verify-window-states.mjs
node --experimental-strip-types scripts/verify-timing.mjs
node --experimental-strip-types scripts/verify-refusals.mjs
```

## How this codebase tests things that need two machines

Almost every defect that ever reached a user here passed a green build, because
the failing path needed a Mac, a receiver and a network to reach. The response
has been consistent, and new work should follow it:

**Extract the decision as a pure value, then assert it.** `SendGate` decides
what to shed without a socket. `Cadence` picks a frame rate without a display.
`PopoverLayout.ordered` returns the sections without a view. `DisplayPlacement`
answers which edge without a second monitor. Frontend equivalents live in
`windows/src/*.ts` with a `scripts/verify-*.mjs` runner wired into both CI jobs.

**Then break it on purpose.** An assertion that still passes with the fix
reverted is worth nothing, and this project has written a few. Delete the guard,
watch a named test fail, put it back. If nothing fails, the test is decoration —
say so rather than keeping it.

## The failure this project keeps repeating

Worth knowing before writing anything user-facing, because it has shipped
repeatedly in different clothes: **the app knows a specific fact and displays a
generic one.**

A refused session showed "Reconnecting…". A display placed to the left said
nothing at all. An idle desktop was read as a dead capture and as a congested
link, and both times something was restarted or degraded for it. In every case
the information existed and the interface declined to say it, and in every case
the user reasonably concluded the app was broken — because from outside there is
no difference.

When adding a state, the question is not "what should this show" but "what does
the app already know here that it is not saying".

## Setting it up on a machine

<details>
<summary>A prompt that knows where the human steps are</summary>

```text
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
   window onto the new display, then the HUD should show frames arriving.
   A near-black screen with capture near 0 fps is CORRECT for an empty desktop.
   NOTE: this browser page counts as a receiver, and only one is allowed at a
   time. Close it before connecting the real receiver, or that one is refused.

WINDOWS RECEIVER (run this part on the Windows laptop):
7. Install Rust (https://rustup.rs) and Node 22+.
8. cd windows && npm ci && npx tauri build
9. Run the installer from windows/src-tauri/target/release/bundle/nsis/
   SmartScreen will warn because it is unsigned: More info > Run anyway.
10. The app finds the Mac over Bonjour. Enter the 4-digit PIN the Mac shows.
    Both machines must be on the same network, on 5 GHz Wi-Fi or Ethernet.

USEFUL TO KNOW:
- Ports 8787 and 8788 must not be blocked.
- Keys in the receiver: F fullscreen, H toggle HUD, K force a keyframe,
  A cycle decode mode, F8 forward input to the Mac.
- macOS decides where the second display goes and usually puts it on the LEFT.
  Push the cursor that way to reach it; System Settings > Displays moves it.
- Read README.md "Known limits" before reporting a bug — the 60 Hz cap, the
  ~1920x1200 geometry ceiling and no-HDCP are properties of Apple's private
  API, not defects.
```

</details>
