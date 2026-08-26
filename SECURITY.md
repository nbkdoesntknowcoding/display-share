# Security

## Reporting

Please report vulnerabilities **privately**, through this repository's
**Security** tab → *Report a vulnerability*. That opens a draft advisory only
maintainers can see.

Please do not open a public issue for anything in the "in scope" list below.

This is a small project with no security team and no paid support. A realistic
expectation is a first reply within a week. If something is being actively
exploited, say so in the title and it will be looked at sooner.

## In scope

Display Share puts a video stream and an input channel on your local network, so
the interesting failures are about who is allowed to reach them:

- **Pairing bypass** — receiving video, or having input accepted, without
  completing the PIN exchange. Input forwarding in particular is refused until a
  device is paired, and a way around that is the highest-severity report here.
- **Token handling** — pairing tokens are stored hashed. A way to recover a
  usable token from what is written to disk, or to replay one from another
  device, is in scope.
- **Input injection** — the Mac injects `CGEvent`s on behalf of a paired
  receiver. Anything that lets an unpaired party drive that is in scope.
- **The helper process** — `vd_helper` holds the virtual display and speaks a
  local IPC protocol. Anything that lets an unrelated local process drive it, or
  escalate through it, is in scope.
- **Path handling in the updater** — both apps download release assets. Anything
  that writes outside the intended location is in scope.

## Not vulnerabilities

Stated plainly, because these get reported and they are deliberate:

- **The binaries are unsigned.** Display Share is open source and does not buy
  code signing certificates, so macOS and SmartScreen both warn on first launch.
  That is a known, documented trade — see [docs/distribution.md](docs/distribution.md).
  Build it yourself and the warning does not appear.
- **It uses a private Apple API.** `CGVirtualDisplay` is how a real virtual
  display is created at all. It is the project's central technique, not an
  oversight, and it is why this cannot ship on the Mac App Store.
- **It records the screen.** It captures the virtual display it creates, and
  macOS shows the purple recording indicator exactly as it does for any other
  capture app. That indicator appearing is correct behaviour.
- **Traffic on your LAN is not encrypted.** The stream is plain WebSocket on the
  local network, gated by pairing. If your threat model includes someone on your
  own LAN reading it, this is not the tool for you today — but a report saying
  so is a feature request, and a welcome one, rather than a vulnerability.

## Scope of the code

Only this repository. The reference projects named in the README are separate
and should be reported to their own maintainers.
