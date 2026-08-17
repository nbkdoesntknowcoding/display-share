# Phase 0 — Feasibility Spike Findings

**Verdict: GO.** Every load-bearing assumption in the research doc holds on the target
hardware. Two corrections and one significant new gotcha are recorded below.

| | |
|---|---|
| **Host** | Mac mini, Apple M4 (`Mac16,10`) |
| **OS** | macOS **26.2** (Tahoe), build **25C56** |
| **Toolchain** | Swift 6.2.3, Xcode default toolchain |
| **Date** | 17 Aug 2026 |
| **Spike** | `mac/spike` — `vdspike create | capture | bench | probe` |

---

## Task 0.1 — CGVirtualDisplay works

All four private classes are present and intact on macOS 26.2 / Apple Silicon:
`CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`,
`CGVirtualDisplayMode`. The class symbols are exported from the SDK's
`CoreGraphics.tbd`, so they link directly — no `dlsym` indirection needed.

A 1920×1080 @ 60 Hz display was created, verified present in
`CGGetActiveDisplayList` with correct geometry (bounds, online, active,
not-builtin, vendor/product/serial matching what we set), and removed cleanly on
release with the display list returning to its exact prior state. No orphans
across dozens of create/destroy cycles.

**Provenance note.** `CGVirtualDisplayPrivate.h` was written from ObjC **runtime
introspection** of CoreGraphics on this machine (`class_copyPropertyList` /
`class_copyMethodList`), so every type matches the real ABI — all the integer
fields are 32-bit `unsigned int`, not `NSUInteger`. No source was copied from the
GPL-3.0 references (`opendisplay`, `Lumen`, `Sunshine`, `moonlight-qt`).

### Correction to the research doc: the 60 Hz cap is a *mode* ceiling

The research doc says virtual displays "cap at 60 Hz". Refined: **every mode the
display advertises is 60.00 Hz** — confirmed across all 24 offered modes. This is
a property of the advertised mode table, not a hard limiter on capture (see 0.3).

### Correction: HiDPI is offered but not adopted

With `hiDPI = 1` and `maxPixelsWide/High` at 2× the point size, macOS **offers** a
`1920×1080 pt / 3840×2160 px @ 2.0x` mode — but **adopts the 1× mode by default**.
Reaching 2× requires an explicit `CGDisplaySetDisplayMode`.

`CGDisplayCopyAllDisplayModes` **hides the 2× variant unless you pass
`kCGDisplayShowDuplicateLowResolutionModes`** — it is treated as a duplicate of
the 1× entry at the same point size. Querying with `nil` options makes HiDPI modes
look like they do not exist.

For a 1080p receiver panel, the 1× mode is the one we want anyway: native pixels,
no downscale, one quarter the pixels to encode. HiDPI is a Phase 2/4 sharpness-vs-cost
decision, not a blocker.

### ⚠️ New gotcha: CoreGraphics snapshots display config per process

This cost real debugging time and **will** bite the product, so it is written up in full.

CoreGraphics caches its view of the display set **per process**, and refreshes it
only when the process *services* a display-reconfiguration notification. In a
process that never receives one, the cached view is frozen forever. Symptom:
`CGDisplayCopyDisplayMode(virtualDisplayID)` returns `nil` and
`CGDisplayCopyAllDisplayModes` returns empty, **even though the display is
demonstrably online with correct bounds** — while the same calls work fine for the
real monitor in the same process.

Two independent triggers, both reproducible:

1. **Querying display modes before the virtual display is created.** The first
   mode query establishes the snapshot; the later display is permanently absent from it.
2. **Registering `CGDisplayRegisterReconfigurationCallback` without servicing it.**
   A bare CLI never receives the notification (`0` events observed across a
   display add), and registration then blocks the refresh outright.

Consequences for the product:

- The SwiftUI app runs a real `NSApplication` run loop and will receive these
  notifications normally — this is largely a spike artifact.
- **`vd_helper` (Task 1.1) is a bare executable and must run `CFRunLoopRun()`** if it
  queries display geometry, or its view will go stale.
- Tasks **3.3** (resolution negotiation) and **4.2** (sleep/wake + reconfiguration)
  depend on a fresh view of geometry. Both must verify they observe reconfiguration
  events rather than assuming them.
- Any diagnostic that enumerates displays at startup can silently poison the
  process's own later queries. Order matters.

---

## Task 0.2 — ScreenCaptureKit captures the virtual display

ScreenCaptureKit sees the virtual display in `SCShareableContent` and an `SCStream`
pinned to it via `SCContentFilter(display:excludingWindows:)` delivers real pixels.

Captured PNGs are the genuine virtual desktop — wallpaper and menu bar at
**1920×1080**, unmistakably distinct from the 2560×1080 main display. Measured
rather than eyeballed: mean luma 19/255 on the dark default wallpaper, **92.3%
non-black**, **2262 unique colours** on a sampled grid. Not black, not a duplicate.

### An idle virtual desktop emits `.idle`, not pixels

Initially every frame was byte-identical and only 32 of 100 frames arrived. That is
**correct ScreenCaptureKit behaviour**: it sets `SCFrameStatus.idle` and does not
re-send unchanged surfaces. An empty desktop never changes, so this proves nothing
either way — a real trap for anyone benchmarking against an idle screen.

`AnimatedContent` places a 60 Hz colour-cycling window on the display to force
genuine change. With it: **200/200 frames captured, 199/199 differ from the
previous frame, 0 dropped, 57.8 fps of a requested 60.**

### Capture callback back-pressure is real

Writing PNGs inside the `SCStreamOutput` callback drops throughput from **57.8 fps
to 22.8 fps**. This is direct empirical support for Task 1.2's requirement: a
bounded frame queue that drops oldest, with all downstream work off the capture
thread. Never block the capture callback.

### Screen Recording permission — caveat

Permission was already granted to the responsible parent process, and persistence
across relaunch was confirmed over many runs. **A fresh TCC prompt was not
observed**, because a non-bundled CLI has no TCC identity of its own — it inherits
the responsible parent (Terminal / the launching app). The shipping signed app gets
its own entry; first-run prompting is genuinely exercised in **Task 6.3**, not here.

---

## Task 0.3 — Baseline capture cost

1920×1080, animated content driving every frame, 10 s per measurement, **each rate in
a fresh process** (see the staleness gotcha — reusing one process corrupts runs 2+).

| Target | Achieved | Mean | p50 | p95 | Max | Process CPU |
|---:|---:|---:|---:|---:|---:|---:|
| 30 fps | **29.4 fps** | 33.99 ms | 33.77 ms | 35.65 ms | 37.75 ms | 1.6% |
| 60 fps | **57.7 fps** | 17.32 ms | 17.15 ms | 18.82 ms | 20.56 ms | 2.3% |
| 120 fps | **63.8 fps** | 15.67 ms | 12.24 ms | 22.61 ms | 34.46 ms | 2.9% |

**Cost attribution.** Absolute system-wide CPU is meaningless here — this machine has
unrelated load. Measuring the identical scene (virtual display + animation) *without*
a capture stream gives a clean delta:

| Scenario | Process CPU | System-wide busy |
|---|---:|---:|
| Baseline — display + animation, no capture | 0.9% | 23.5% |
| With 1080p60 capture | 2.3% | 24.6% |
| **Attributable to capture** | **~1.4%** | **~1.1%** |

**~1.4% of one core to capture 1080p60**, comfortably inside the research doc's
"well under 5% CPU on Apple Silicon". Frame pacing is tight: p95 of 18.82 ms against
a 16.67 ms target, max 20.56 ms — no pathological stalls.

**60 Hz ceiling confirmed.** Requesting 120 fps yields **63.8 fps** with 280 frames
marked `.idle` — the surface simply does not update faster. Capture is not *hard*
limited to 60, but there is nothing above ~60 to capture. Targeting 60 is correct.

---

## Go / No-Go

**GO.** The private API works on the exact target hardware and OS, ScreenCaptureKit
captures it, and the cost is ~1.4% CPU for 1080p60 — leaving ample headroom for
VideoToolbox encode and the network path in Phase 2.

Carry into Phase 1:

1. `vd_helper` must run a real `CFRunLoopRun()` if it queries display geometry.
2. Bounded, drop-oldest frame queue; never block the capture callback (Task 1.2).
3. Do not enumerate display modes before creating the virtual display.
4. Pass `kCGDisplayShowDuplicateLowResolutionModes` whenever HiDPI modes matter.
5. Treat `SCFrameStatus` properly — `.idle` frames are not new pixels and must not
   count toward throughput or be re-encoded.
