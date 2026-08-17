# Contributing

Thanks for looking. A few things specific to this project.

## Before you build

The Xcode project is **generated** from `mac/project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Edit the YAML — changes made
directly to `DisplayShare.xcodeproj` are overwritten.

```bash
brew install xcodegen
cd mac && xcodegen generate
```

## Licensing rules that matter here

Display Share is **GPL-3.0**. Two rules exist because this project sits near
several other virtual-display implementations:

1. **Do not copy source from other projects** into this one, even GPL-compatible
   ones, without saying so in the PR. The private CoreGraphics interface in
   `mac/CGVirtualDisplayPrivate` was derived by Objective-C runtime
   introspection on a real machine, not copied — keep it that way so its
   provenance stays clean.
2. If you read another project for architecture, **say so in the commit
   message**. Several commits here do exactly that.

## Testing

There are two kinds, and both are expected to pass:

```bash
cd mac
xcodebuild -scheme DisplayShareCore -derivedDataPath ./.build test   # unit
./scripts/test-helper-lifecycle.sh                                  # acceptance
python3 scripts/ws-acceptance.py
```

The acceptance scripts drive the **real** app against a **real** virtual display.
Several of them will move your mouse cursor; they restore it afterwards.

A note on how this codebase treats tests: assertions should be able to **fail**.
A loose assertion that passes regardless of the value is worse than no test,
because it looks like coverage. Two real bugs in this repo were found only after
tightening an assertion that had been passing vacuously.

## The wire protocol

`protocol/SPEC.md` is normative. If you change the framing or control channel:

* update `SPEC.md` first,
* update **both** parsers (`mac/Shared/WireProtocol.swift` and
  `windows/src/protocol.ts`),
* add or update golden vectors in `protocol/vectors/`.

The two parsers are never tested against each other — both run against the same
golden bytes, so a shared misunderstanding cannot pass. That is deliberate and
has already caught a real precision bug.

## Commits

Conventional Commits (`feat:`, `fix:`, `docs:`, `build:`). `release-please`
generates the changelog from them, so the prefix decides the version bump.

Explain **why** in the body, not just what. The diff already says what.

## CI

`actionlint` runs on every push. Workflow files with an invalid expression fail
at startup with zero jobs and no readable error, so lint locally before pushing:

```bash
brew install actionlint && actionlint
```
