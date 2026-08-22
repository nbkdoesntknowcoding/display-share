/**
 * Where a frame's milliseconds go, measured rather than reasoned about.
 *
 * The HUD's `delay` cannot answer this. It reports arrival delay above the best
 * this session has managed — it starts at zero by construction and can only
 * rise, so it says whether things got worse, never what anything costs. Every
 * change made for latency so far has been argued from first principles because
 * this is the number that was available.
 *
 * The one gap nothing could see was the hand-off from the socket to this
 * window: the Rust side reads a frame, the WebView delivers it to `main.ts`,
 * and between those two lines sit the IPC bridge and WebView2. Forwarding
 * frames as JSON once cost about 6.7ms each — they are `Raw` now, and whether
 * that fixed it has never been checked.
 *
 * The two runtimes have no shared monotonic clock, so both sides stamp the wall
 * clock and the pairing key is the sender's timestamp, which is already in
 * every frame. That costs nothing on the wire and needs no spec change.
 */

/**
 * What the Rust side reports for a sampled frame (`ds://handoff`).
 *
 * These names are a contract with `handoff::payload` in
 * `windows/src-tauri/src/handoff.rs`, pinned by a test there. Nothing fails to
 * compile if one side is renamed: the field reads `undefined`, every sample
 * fails to pair, and the HUD row simply never appears.
 */
export interface HandoffSample {
  timestampMicros: number;
  forwardedEpochMicros: number;
}

/**
 * A sample is discarded rather than trusted if it implies a gap outside this
 * range.
 *
 * Wall clocks are the price of measuring across two runtimes: an NTP step
 * between the two stamps produces a number with no relationship to anything.
 * Negative means this window was told about a frame before it was read, which
 * is a clock going backwards, not a fast bridge. The upper bound is loose
 * enough that a genuinely awful hand-off is still reported — the point is to
 * see it, not to hide it — and tight enough to reject a clock jump.
 */
export const PLAUSIBLE_HANDOFF_MS = { min: 0, max: 2_000 };

/** How many recent arrivals are kept for pairing. */
export const ARRIVAL_HISTORY = 240;

export interface Summary {
  /** Middle of the samples, not the mean: one stall must not move it. */
  medianMs: number;
  /** Worst of the recent samples — where the stutter actually lives. */
  worstMs: number;
  count: number;
}

/**
 * Pairs socket-read stamps from Rust with arrival times in this window.
 *
 * Arrivals are recorded for every frame; only sampled frames are ever paired,
 * but which frames those are is the Rust side's decision, and this side does
 * not know it in advance.
 */
export class HandoffMeter {
  /** timestampMicros → epoch millis this window received it. */
  private arrivals = new Map<number, number>();
  private samples: number[] = [];
  private readonly keep: number;

  constructor(keep = 60) {
    this.keep = keep;
  }

  /**
   * Records that a frame reached this window.
   *
   * `epochMillis` must come from `performance.timeOrigin + performance.now()`
   * — the wall clock the Rust stamp is also on. `performance.now()` alone is
   * measured from page load and would make every gap look enormous.
   */
  noteArrival(timestampMicros: number, epochMillis: number): void {
    this.arrivals.set(timestampMicros, epochMillis);
    // Bounded: a session runs for hours and every frame passes through here.
    // Insertion order is arrival order, so the oldest key is the first one.
    while (this.arrivals.size > ARRIVAL_HISTORY) {
      const oldest = this.arrivals.keys().next();
      if (oldest.done) break;
      this.arrivals.delete(oldest.value);
    }
  }

  /**
   * Pairs a sample with its arrival. Returns the gap in milliseconds, or
   * `undefined` if it cannot be trusted or the frame is not known.
   *
   * An unknown frame is normal rather than exceptional: the event and the
   * frame travel by different paths, and a sample for a frame this window
   * dropped — or one that arrived before a reconnect cleared the history — has
   * nothing to pair with.
   */
  noteSample(sample: HandoffSample): number | undefined {
    const arrived = this.arrivals.get(sample.timestampMicros);
    if (arrived === undefined) return undefined;

    const gapMs = arrived - sample.forwardedEpochMicros / 1000;
    if (gapMs < PLAUSIBLE_HANDOFF_MS.min || gapMs > PLAUSIBLE_HANDOFF_MS.max) {
      return undefined;
    }

    this.samples.push(gapMs);
    if (this.samples.length > this.keep) this.samples.shift();
    return gapMs;
  }

  /** `undefined` until something has actually been measured. */
  summary(): Summary | undefined {
    if (this.samples.length === 0) return undefined;
    const sorted = [...this.samples].sort((a, b) => a - b);
    return {
      medianMs: sorted[Math.floor(sorted.length / 2)],
      worstMs: sorted[sorted.length - 1],
      count: sorted.length,
    };
  }

  /**
   * Forgets everything. Called on a reconnect: the Rust side starts a new
   * sampler, and pairing a new stamp against an old session's arrival would
   * report a gap that never happened.
   */
  reset(): void {
    this.arrivals.clear();
    this.samples = [];
  }
}

/**
 * A rolling window of durations, for stages this window times end to end.
 *
 * Same reasoning as above: the median describes the common case and the worst
 * describes what is felt, and an average hides both.
 */
export class StageMeter {
  private samples: number[] = [];
  private readonly keep: number;

  // Written out rather than declared as a constructor parameter property:
  // those need code generation, and these modules are verified by Node's
  // --experimental-strip-types, which only removes types.
  constructor(keep = 60) {
    this.keep = keep;
  }

  note(millis: number): void {
    this.samples.push(millis);
    if (this.samples.length > this.keep) this.samples.shift();
  }

  summary(): Summary | undefined {
    if (this.samples.length === 0) return undefined;
    const sorted = [...this.samples].sort((a, b) => a - b);
    return {
      medianMs: sorted[Math.floor(sorted.length / 2)],
      worstMs: sorted[sorted.length - 1],
      count: sorted.length,
    };
  }

  reset(): void {
    this.samples = [];
  }
}

/**
 * One HUD row for a measured stage, or nothing while it has no data.
 *
 * Lives here rather than beside the HUD so CI can run it. Nothing in this
 * project's history suggests "it is only formatting" is a safe reason to leave
 * something unexercised — the receiver's own window states were extracted for
 * exactly this reason, after every defect that reached a user passed a green
 * build.
 *
 * Both numbers, because either alone misleads: the median hides the stall that
 * gets noticed, and the worst describes one moment rather than the session.
 */
export function stageRow(
  label: string,
  summary: Summary | undefined,
  warnAboveMs: number
): Array<[string, string, string?]> {
  // No row at all rather than a zero. A stage that has measured nothing and a
  // stage that costs nothing are different things, and "0.0 ms" says the
  // second when it means the first.
  if (!summary) return [];
  return [
    [
      label,
      `${summary.medianMs.toFixed(1)} / ${summary.worstMs.toFixed(1)} ms`,
      summary.medianMs > warnAboveMs ? "warn" : undefined,
    ],
  ];
}
