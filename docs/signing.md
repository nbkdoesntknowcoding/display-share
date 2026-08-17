# Signing, notarization and distribution

Display Share is distributed by direct download, so both operating systems treat
it as untrusted software until it is signed. This is what that costs and how it
is wired.

> **Current state:** the full pipeline is implemented and exercised, but **no
> certificates exist yet**, so builds are unsigned. `mac/scripts/package-macos.sh`
> reports exactly which stage it skipped rather than producing a DMG that looks
> shippable. Neither Task 6.1 nor 6.2 can be finished until the certificates are
> bought.

---

## macOS — Developer ID + notarization (Task 6.1)

### What's needed

| Item | Detail | Cost |
|---|---|---|
| Apple Developer Program | Individual or Organization | **$99/year** |
| Developer ID Application certificate | From the program; not the free "Apple Development" cert | included |
| App-specific password | appleid.apple.com → Sign-In and Security | free |
| Team ID | 10 characters, in the Apple Developer account page | — |

The free Apple Development certificate is **not** sufficient. It signs for local
use only; Gatekeeper on another Mac rejects it, and notarization refuses it.

### Why notarization and not just signing

Signing alone still produces a warning on first launch. Notarization uploads the
build to Apple, which scans it and issues a ticket; **stapling** attaches that
ticket so Gatekeeper accepts it even offline. Both steps are required for a
download that opens cleanly.

### Local setup

```bash
# Store notary credentials once, in the keychain (preferred over passing
# --apple-id/--password on every invocation).
xcrun notarytool store-credentials "display-share" \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "abcd-efgh-ijkl-mnop"

security find-identity -v -p codesigning   # copy the Developer ID line

export DS_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"
export DS_NOTARY_PROFILE="display-share"
cd mac && ./scripts/package-macos.sh
```

Expected tail on success:

```
signed:     Developer ID
notarized:  yes
```

and `spctl -a -vvv -t install <dmg>` reports `accepted`.

### CI secrets

`.github/workflows/build.yml` uses these. The certificate is imported into an
**ephemeral keychain** that dies with the runner, never the default one.

| Secret | What |
|---|---|
| `MACOS_CERTIFICATE` | `base64 -i cert.p12` of the exported Developer ID cert |
| `MACOS_CERTIFICATE_PASSWORD` | password set when exporting the .p12 |
| `MACOS_SIGN_IDENTITY` | the full `Developer ID Application: …` string |
| `APPLE_ID` | Apple ID email |
| `APPLE_APP_PASSWORD` | app-specific password |
| `APPLE_TEAM_ID` | Team ID |

```bash
security export -k login.keychain -t identities -f pkcs12 -o cert.p12
base64 -i cert.p12 | pbcopy
gh secret set MACOS_CERTIFICATE --repo <owner>/<repo>
```

### Notarization must run on macOS

`notarytool` and `stapler` ship only with Xcode. The Linux VPS that hosts the
downloads (Task 7.2) cannot perform this step, which is why the workflow uses a
`macos-latest` runner.

### Signing order

Nested code first, outermost last — a later inner signature invalidates the outer
one:

1. `Contents/MacOS/vd_helper` (with entitlements — it is a sibling executable, not a framework)
2. `Contents/Frameworks/DisplayShareCore.framework`
3. `DisplayShare.app`
4. the `.dmg` itself, notarized and stapled separately

### Hardened Runtime and the private API

Hardened Runtime is required for notarization and is enabled. Note what is *not*
used: App Sandbox is off, because `CGVirtualDisplay` is a private API and the app
spawns a sibling helper process. That is also why Display Share cannot ship on
the Mac App Store — App Review rejects private API use outright.

Notarization is a **malware scan, not an API audit**. It does not inspect for
private API use, so it is not expected to object. The real risk is a future macOS
version removing `CGVirtualDisplay`, which is tracked in the research doc's risk
table, not here.

---

## Windows — code signing (Task 6.2)

### OV vs EV: the decision

| | OV (Organization Validation) | EV (Extended Validation) |
|---|---|---|
| Cost | ~$200–400/year | ~$400–700/year |
| Hardware | none — a file | **HSM / USB token required** |
| SmartScreen | reputation accrues **slowly**, over downloads and time | trusted **immediately** |
| CI friendliness | good — cert in a secret | poor — token cannot be handed to a hosted runner |
| Validation | business documents | stricter, plus notarised documents |

**Recommendation: start with OV.**

Reasoning, in order of weight:

1. **EV cannot be used from hosted CI.** An HSM token has to be physically
   present. Using EV means either a self-hosted Windows runner with the token
   plugged in, or a cloud HSM service (extra cost and setup). For a solo project
   that is a large amount of ceremony.
2. **The SmartScreen advantage is temporary.** OV reputation builds with download
   volume; EV buys a head start, not a permanent difference.
3. **Cost.** At this stage the difference is better spent elsewhere.

**Revisit EV if** early users report being blocked and abandoning the install —
that is a real conversion problem, and then the token ceremony is worth it.

### What the user sees, honestly

With an OV certificate and no reputation yet, Windows shows *"Windows protected
your PC"* with a **More info → Run anyway** path. The install works; it just
looks alarming. This must be stated on the download page (Task 7.2), not hidden.

Unsigned is worse: a stronger warning, and some environments block it outright.

### CI secrets

| Secret | What |
|---|---|
| `WINDOWS_CERTIFICATE` | base64 of the .pfx |
| `WINDOWS_CERTIFICATE_PASSWORD` | its password |

`tauri-action` picks these up automatically. Left unset it produces an unsigned
installer, which is fine for internal testing and **not** fine for release —
Task 6.2 is explicitly not done until signing is wired.

### The `.exe` cannot be built on macOS

`tauri build` targets the host platform. On macOS, `--bundles nsis` compiles the
binary and then **silently produces no installer**, which is easy to mistake for
success. Building the NSIS installer needs a Windows host or the
`windows-latest` runner in the workflow.

---

## Checklist before the first public release

- [ ] Apple Developer Program active, Developer ID cert exported
- [ ] macOS secrets set; a tagged build reports `spctl … accepted`
- [ ] Windows OV certificate bought, `.pfx` exported, secrets set
- [ ] Download page states the SmartScreen warning plainly
- [ ] `.dmg` tested on a Mac that has never run Display Share
- [ ] `.exe` tested on a clean Windows 11 install
