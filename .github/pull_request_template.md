## What changes, and why

<!-- The reasoning matters more than the diff here. If a comment in the code
     would not explain this to someone in six months, the description should. -->

## How it was verified

<!-- Please be specific, and say plainly what was NOT verified. A change that
     builds and passes tests but was never run is a normal thing to submit —
     saying so is what makes it safe to review. -->

- [ ] `xcodebuild -scheme DisplayShareCore -derivedDataPath ./.build test` (from `mac/`)
- [ ] `cargo test --manifest-path src-tauri/Cargo.toml` (from `windows/`)
- [ ] The `node --experimental-strip-types scripts/verify-*.mjs` checks (from `windows/`)
- [ ] Run against a real Mac and receiver

## Anything a reviewer should be suspicious of

<!-- Assertions that might not fail if the fix were reverted are worth calling
     out. This project has shipped a few, and the habit of tamper-testing them —
     break the fix, watch a test fail — has caught more than one. -->
