/**
 * Explanations that have to outlive the disconnect that causes them.
 *
 * Run with `node --experimental-strip-types scripts/verify-refusals.mjs`.
 *
 * This exists because of a real session lost to it. The Mac refuses a second
 * receiver with `busy` and then closes the socket. The receiver displayed the
 * refusal correctly — and roughly a hundred milliseconds later the disconnect
 * handler wrote "Disconnected. Reconnecting…" straight over it. What was left
 * was a spinner that never resolved, which reads as a broken app rather than an
 * occupied one, and the information needed to fix it in one click had been on
 * screen and was erased.
 *
 * Nothing about that is reachable without two receivers and one Mac, which is
 * why it survived to reach a user.
 */
import assert from "node:assert/strict";

const { refusalExplanation, disconnectStatus } = await import("../src/errors.ts");

let checks = 0;
function check(name, fn) {
  fn();
  checks++;
  console.log(`  ok  ${name}`);
}

// ------------------------------------------------------------ the regression

check("a busy sender survives the disconnect it triggers", () => {
  const sticky = refusalExplanation("busy");
  assert.ok(sticky, "busy must produce an explanation");
  assert.equal(
    disconnectStatus(sticky),
    sticky,
    "the disconnect that follows a refusal must not overwrite it"
  );
});

check("the busy message says what to do, not just what happened", () => {
  const text = refusalExplanation("busy").toLowerCase();
  assert.ok(
    text.includes("close") || text.includes("wait"),
    `no action offered: ${text}`
  );
  // The raw sender text names the mechanism; the user needs the remedy.
  assert.ok(
    !text.includes("another receiver is already connected"),
    "this is the raw wire message, which describes plumbing rather than a fix"
  );
});

// ------------------------------------------------------- the ordinary case

check("an ordinary disconnect still says it is reconnecting", () => {
  assert.equal(disconnectStatus(null), "Disconnected. Reconnecting…");
});

check("a transient failure is not pinned to the screen", () => {
  // Anything without a deliberate explanation must return null, so a stale
  // reason cannot outlive the moment it stopped being true.
  for (const code of ["", "unknown", "input_unavailable", "internal", "timeout"]) {
    assert.equal(
      refusalExplanation(code),
      null,
      `${code} must not become sticky`
    );
    assert.equal(disconnectStatus(refusalExplanation(code)), "Disconnected. Reconnecting…");
  }
});

console.log(`\n${checks} checks passed`);
