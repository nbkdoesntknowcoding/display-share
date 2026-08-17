/**
 * Runs the TypeScript protocol parser against protocol/vectors/.
 *
 * The Swift and TypeScript implementations are never tested against each other
 * — both are tested against the same golden bytes, so a shared misunderstanding
 * cannot pass.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { execSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const vectorsDir = join(here, "..", "..", "protocol", "vectors");

// Compile protocol.ts to JS on the fly so the test runs the real source.
const outDir = join(here, ".vectors-build");
// Quote the path: the repo directory contains a space.
execSync(`npx tsc src/protocol.ts --outDir "${outDir}" --module esnext --target es2022 --moduleResolution bundler`, {
  cwd: join(here, ".."),
  stdio: "inherit",
});
const { decodeVideoMessage, encodeVideoMessage, codecStringFromAnnexB } = await import(
  join(outDir, "protocol.js")
);

const manifest = JSON.parse(readFileSync(join(vectorsDir, "manifest.json"), "utf8"));
let passed = 0;
let failed = 0;

const check = (label, ok, detail = "") => {
  if (ok) { console.log(`  ✅ ${label}${detail ? ` (${detail})` : ""}`); passed++; }
  else { console.log(`  ❌ ${label}${detail ? ` (${detail})` : ""}`); failed++; }
};

console.log("=== TypeScript parser vs golden vectors ===\n");

for (const vector of manifest.vectors) {
  const bytes = new Uint8Array(readFileSync(join(vectorsDir, vector.file)));
  const result = decodeVideoMessage(bytes);

  if (vector.expect === "accept") {
    if (!result.ok) {
      check(vector.file, false, `rejected: ${JSON.stringify(result.error)}`);
      continue;
    }
    const m = result.message;
    const okFields =
      m.isKeyframe === vector.isKeyframe &&
      m.timestampMicros === BigInt(vector.timestampMicros) &&
      m.payload.length === vector.payloadBytes &&
      (codecStringFromAnnexB(m.payload) ?? null) === (vector.codecString ?? null);
    // Re-encoding must reproduce the vector byte for byte.
    const reencoded = encodeVideoMessage(m);
    const identical =
      reencoded.length === bytes.length && reencoded.every((b, i) => b === bytes[i]);
    check(vector.file, okFields && identical,
      okFields ? (identical ? "parsed + re-encoded" : "re-encode mismatch") : "field mismatch");
  } else {
    check(vector.file, !result.ok,
      result.ok ? "accepted but should have been rejected" : `rejected: ${result.error.kind}`);
  }
}

console.log(`\n=== ${passed} passed, ${failed} failed ===`);
process.exit(failed ? 1 : 0);
