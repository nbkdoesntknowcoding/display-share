/**
 * The receiver window's state machine (Command 10 of the UI/UX audit).
 *
 * Run with `node --experimental-strip-types scripts/verify-window-states.mjs`.
 *
 * This exists because of a gap this project has hit repeatedly: every defect
 * that reached a user passed CI, because nothing in CI ran the receiver's
 * frontend at all. The states asserted here are only reachable through a live
 * WebSocket, a paired Mac and a decoded H.264 frame — so before the decision
 * was extracted into a pure function, the only way to see a mid-session drop
 * was to unplug something.
 */
import assert from "node:assert/strict";

const { windowClasses } = await import("../src/components/window.ts");

let checks = 0;
function check(name, fn) {
  fn();
  checks++;
  console.log(`  ok  ${name}`);
}

/// All eight combinations. The interesting bugs live in the corners, not in
/// the two states anyone would open by hand.
const every = [];
for (const overlayVisible of [true, false]) {
  for (const hasLiveFrame of [true, false]) {
    for (const hudWanted of [true, false]) {
      const state = { overlayVisible, hasLiveFrame, hudWanted };
      every.push({ state, classes: windowClasses(state) });
    }
  }
}

console.log("receiver window states");

check("startup shows the card over an empty window", () => {
  const c = windowClasses({ overlayVisible: true, hasLiveFrame: false, hudWanted: false });
  assert.ok(!c.overlay.includes("hidden"), "card must be up");
  assert.ok(!c.overlay.includes("over-session"), "nothing behind it to dim");
  assert.ok(!c.canvas.includes("live"), "canvas has never had a frame");
  assert.ok(!c.mark.includes("hidden"), "the app names itself on the connect screen");
});

check("streaming is canvas only", () => {
  const c = windowClasses({ overlayVisible: false, hasLiveFrame: true, hudWanted: false });
  assert.deepEqual(c.overlay, ["hidden"]);
  assert.deepEqual(c.canvas, ["live"], "full brightness, no dim");
  assert.deepEqual(c.mark, ["hidden"], "zero chrome while streaming");
  assert.deepEqual(c.hud, ["hidden"], "the HUD is on a hotkey, not always on");
});

check("a mid-session drop dims the picture instead of removing it", () => {
  const c = windowClasses({ overlayVisible: true, hasLiveFrame: true, hudWanted: false });
  assert.ok(c.canvas.includes("live"), "the last frame stays on screen");
  assert.ok(c.canvas.includes("dimmed"), "dimmed, so the card reads over it");
  assert.ok(c.overlay.includes("over-session"), "no opaque background over a live canvas");
  assert.ok(!c.overlay.includes("hidden"));
});

/// The audit's instruction, as an invariant rather than a state: "do NOT drop
/// the user to a blank window."
check("a canvas that has had a frame is never blanked", () => {
  for (const { state, classes } of every) {
    if (!state.hasLiveFrame) continue;
    assert.ok(
      classes.canvas.includes("live"),
      `blanked the canvas in ${JSON.stringify(state)}`
    );
  }
});

check("nothing is dimmed before there is anything to dim", () => {
  for (const { state, classes } of every) {
    if (state.hasLiveFrame) continue;
    assert.ok(!classes.canvas.includes("dimmed"), JSON.stringify(state));
    assert.ok(!classes.overlay.includes("over-session"), JSON.stringify(state));
  }
});

/// Chrome and the card appear together or not at all: the mark is part of the
/// connect screen, not of the stream.
check("the app mark is visible exactly when the card is", () => {
  for (const { state, classes } of every) {
    assert.equal(
      classes.mark.includes("hidden"),
      !state.overlayVisible,
      JSON.stringify(state)
    );
  }
});

/// The HUD once vanished for an entire session because it was hidden when the
/// card went up and never restored when the stream came back, needing two
/// presses of H to recover.
check("the HUD comes back when the stream does", () => {
  const dropped = windowClasses({ overlayVisible: true, hasLiveFrame: true, hudWanted: true });
  assert.deepEqual(dropped.hud, ["hidden"], "hidden while the card is up");
  const resumed = windowClasses({ overlayVisible: false, hasLiveFrame: true, hudWanted: true });
  assert.deepEqual(resumed.hud, [], "and back when it returns");
});

check("the HUD stays away when it was never asked for", () => {
  for (const { state, classes } of every) {
    if (state.hudWanted) continue;
    assert.ok(classes.hud.includes("hidden"), JSON.stringify(state));
  }
});

console.log(`\n${checks} checks passed across ${every.length} states`);
