/**
 * The per-stage timing meters (Phase 3 of the latency plan).
 *
 * Run with `node --experimental-strip-types scripts/verify-timing.mjs`.
 *
 * These numbers only ever appear during a live session with a Mac at the other
 * end, on a HUD nobody is reading at the moment a clock steps — so a meter that
 * quietly reports nonsense would be believed. Every guard below exists because
 * the failure it prevents is invisible: a hand-off measured against the wrong
 * clock reads as a plausible few hundred milliseconds, and a map that is never
 * trimmed leaks slowly enough to look like something else entirely.
 */
import assert from "node:assert/strict";

const { HandoffMeter, StageMeter, stageRow, ARRIVAL_HISTORY, PLAUSIBLE_HANDOFF_MS } =
  await import("../src/timing.ts");

let checks = 0;
function check(name, fn) {
  fn();
  checks++;
  console.log(`  ok  ${name}`);
}

// --------------------------------------------------------------- the pairing

check("a paired sample reports the gap between the two stamps", () => {
  const meter = new HandoffMeter();
  // Rust read the frame at epoch 1_000_000_000.000 ms; this window got it 4ms
  // later. The sender's timestamp is just the key — its value means nothing
  // here, and deliberately does not look like either epoch.
  meter.noteArrival(7_777, 1_000_000_000.0 + 4);
  const gap = meter.noteSample({
    timestampMicros: 7_777,
    forwardedEpochMicros: 1_000_000_000_000,
  });
  assert.equal(gap, 4);
});

check("a sample for a frame this window never saw is not invented", () => {
  const meter = new HandoffMeter();
  meter.noteArrival(1, 1000);
  assert.equal(
    meter.noteSample({ timestampMicros: 999, forwardedEpochMicros: 1_000_000 }),
    undefined,
    "a dropped frame, or one from before a reconnect, has nothing to pair with"
  );
  assert.equal(meter.summary(), undefined, "and must not count as a measurement");
});

// ----------------------------------------------------------------- the clock

check("a backwards clock is discarded rather than reported as zero", () => {
  const meter = new HandoffMeter();
  // Arrival stamped BEFORE the socket read: only a clock stepping can do this.
  meter.noteArrival(1, 1000);
  assert.equal(
    meter.noteSample({ timestampMicros: 1, forwardedEpochMicros: 2_000_000 }),
    undefined
  );
  assert.equal(meter.summary(), undefined, "a rejected sample must not become a data point");
});

check("an implausibly large gap is discarded", () => {
  const meter = new HandoffMeter();
  const beyond = PLAUSIBLE_HANDOFF_MS.max + 1;
  meter.noteArrival(1, 1000 + beyond);
  assert.equal(meter.noteSample({ timestampMicros: 1, forwardedEpochMicros: 1_000_000 }), undefined);
});

check("a bad hand-off is still reported — the bound rejects clocks, not slowness", () => {
  const meter = new HandoffMeter();
  // 200ms is a disaster for one IPC hop, and exactly what this exists to catch.
  meter.noteArrival(1, 1200);
  assert.equal(meter.noteSample({ timestampMicros: 1, forwardedEpochMicros: 1_000_000 }), 200);
});

// ----------------------------------------------------------------- the shape

check("the summary reports the middle and the worst, not the mean", () => {
  const meter = new StageMeter();
  // One outlier among small values: a mean would report ~18ms and describe
  // neither the common case nor the stall.
  for (const ms of [2, 3, 4, 5, 100]) meter.note(ms);
  const summary = meter.summary();
  assert.equal(summary.medianMs, 4, "the median describes the common case");
  assert.equal(summary.worstMs, 100, "the worst is what gets felt");
  assert.equal(summary.count, 5);
});

check("nothing is reported before anything is measured", () => {
  assert.equal(new StageMeter().summary(), undefined);
  assert.equal(new HandoffMeter().summary(), undefined);
});

check("a rolling window forgets, so a stall does not haunt the session", () => {
  const meter = new StageMeter(4);
  meter.note(500);
  for (const ms of [1, 2, 3, 4]) meter.note(ms);
  assert.equal(meter.summary().worstMs, 4, "the stall has rolled out of the window");
  assert.equal(meter.summary().count, 4);
});

// ---------------------------------------------------------------- the memory

check("arrivals are bounded — every frame of a long session passes through", () => {
  const meter = new HandoffMeter();
  const total = ARRIVAL_HISTORY * 3;
  for (let i = 0; i < total; i++) meter.noteArrival(i, 1000 + i);

  // The oldest are gone: pairing one proves the map was trimmed, without
  // reaching into a private field to count it.
  assert.equal(
    meter.noteSample({ timestampMicros: 0, forwardedEpochMicros: 1_000_000 }),
    undefined,
    "the first frame of the session must not still be held"
  );
  const recent = total - 1;
  assert.notEqual(
    meter.noteSample({ timestampMicros: recent, forwardedEpochMicros: (1000 + recent - 3) * 1000 }),
    undefined,
    "but a recent frame is still pairable"
  );
});

check("a reconnect forgets both halves", () => {
  const meter = new HandoffMeter();
  meter.noteArrival(1, 1004);
  meter.noteSample({ timestampMicros: 1, forwardedEpochMicros: 1_000_000 });
  assert.notEqual(meter.summary(), undefined);

  meter.reset();
  assert.equal(meter.summary(), undefined, "old measurements must not survive");
  assert.equal(
    meter.noteSample({ timestampMicros: 1, forwardedEpochMicros: 1_000_000 }),
    undefined,
    "and a new session's stamp must not pair with an old session's arrival"
  );
});

// ------------------------------------------------------------------ the row

check("a stage that has measured nothing shows no row, not a zero", () => {
  assert.deepEqual(
    stageRow("handoff", undefined, 12),
    [],
    '"0.0 ms" would read as free when it means unmeasured'
  );
});

check("a measured stage shows both numbers", () => {
  const [row] = stageRow("handoff", { medianMs: 3.25, worstMs: 41.5, count: 9 }, 12);
  assert.deepEqual(row, ["handoff", "3.3 / 41.5 ms", undefined]);
});

check("the row warns on the median, not on one bad moment", () => {
  const [spike] = stageRow("handoff", { medianMs: 4, worstMs: 900, count: 9 }, 12);
  assert.equal(spike[2], undefined, "a single stall must not leave the HUD amber");

  const [sustained] = stageRow("handoff", { medianMs: 40, worstMs: 45, count: 9 }, 12);
  assert.equal(sustained[2], "warn", "but a stage that is always slow must show it");
});

console.log(`\n${checks} checks passed`);
