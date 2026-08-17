# Distribution: unsigned, and what that means

Display Share is open source and **ships unsigned on both platforms**. That is a
deliberate decision, not an oversight: code signing certificates cost roughly
$99/year (Apple) and $200–400/year (Windows OV), and this project does not buy
them.

The consequence is that both operating systems will warn on first launch. This
page documents exactly what users see and what they click, because a download
page that hides this wastes people's time and looks like malware behaviour.

---

## What users see

### macOS

The `.dmg` opens, but launching the app gives:

> **"DisplayShare" cannot be opened because Apple cannot check it for malicious software.**

**To open it:**

1. Try to open the app once — the warning appears; dismiss it.
2. Go to **System Settings → Privacy & Security**.
3. Scroll to the Security section. There is now a line about DisplayShare being
   blocked, with an **Open Anyway** button.
4. Click it and confirm.

This is needed once per installed copy.

Terminal equivalent, for people who prefer it:

```bash
xattr -d com.apple.quarantine /Applications/DisplayShare.app
```

That removes the quarantine flag the browser attached to the download. It does
not make the app signed; it tells Gatekeeper you accept the risk.

### Windows

The installer triggers SmartScreen:

> **Windows protected your PC**

**To install:** click **More info**, then **Run anyway**.

---

## Why we don't just tell people to trust us

Because they shouldn't, and because they don't have to. This is the honest
position for an unsigned open-source app:

* The source is public. Anyone can read what it does.
* **Building from source avoids the warning entirely** — a locally built app is
  ad-hoc signed by your own machine and is not quarantined. See
  [Building from source](#building-from-source).
* Display Share asks for Screen Recording and (optionally) Accessibility. Those
  are strong permissions, and "just click through the warning" is a bad habit to
  teach. The README explains what each permission is used for and what it is
  not.

---

## Building from source

This is the recommended path for anyone uncomfortable with the warnings, and it
is not hard.

```bash
# macOS sender
brew install xcodegen create-dmg
cd mac && ./scripts/package-macos.sh      # produces .release/DisplayShare-<v>.dmg

# or just build and run, no packaging
xcodegen generate && xcodebuild -scheme DisplayShare -configuration Release \
  -derivedDataPath ./.build build
```

```bash
# Windows receiver — needs Rust and Node
cd windows && npm ci && npx tauri build
```

A build you made yourself carries no quarantine attribute, so macOS launches it
without complaint.

---

## The signing pipeline still exists

`mac/scripts/package-macos.sh` implements the full chain — `codesign` →
`notarytool submit --wait` → `stapler staple` → styled `.dmg` — and switches it
on automatically if the credentials are ever present:

```bash
export DS_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
export DS_NOTARY_PROFILE="display-share"
cd mac && ./scripts/package-macos.sh
```

Without them it reports the truth rather than producing something that looks
shippable:

```
universal:  yes (arm64 + x86_64)
signed:     NO — ad-hoc only
notarized:  NO
```

CI reports the Gatekeeper verdict in the run summary but **does not fail on it**,
because unsigned is the expected state here.

### If signing ever becomes worth it

| Option | Platform | Cost | Notes |
|---|---|---|---|
| [SignPath.io](https://signpath.io) | Windows | **free for OSS** | Certificate donated to qualifying open-source projects; integrates with GitHub Actions |
| Azure Trusted Signing | Windows | ~$10/month | Cheaper than a traditional cert, no HSM token |
| OV certificate | Windows | $200–400/yr | Reputation accrues slowly with download volume |
| Apple Developer Program | macOS | $99/yr | **No free equivalent exists** for Developer ID |

If a Windows certificate arrives, set `WINDOWS_CERTIFICATE` and
`WINDOWS_CERTIFICATE_PASSWORD` as repository secrets and `tauri-action` picks
them up with no other change. For macOS, set the six secrets listed in
`.github/workflows/build.yml`.

Recorded for the future: if a Windows cert is ever bought rather than donated,
prefer **OV over EV**. EV grants immediate SmartScreen trust but requires an HSM
token that cannot be handed to a hosted CI runner, forcing either a self-hosted
Windows runner or a cloud HSM. EV's advantage is also temporary, since OV
reputation builds with downloads.

---

## Updates

Both apps check **GitHub Releases**; there is no server to run.

| | macOS | Windows |
|---|---|---|
| Mechanism | GitHub releases API, notify + link | Tauri updater |
| Downloads automatically | no | only after you click **Update and restart** |
| Installs automatically | **no** — opens the release page | yes, after you agree |
| Signature on the payload | n/a | required, minisign keypair |

**Neither updates silently, on purpose.** Display Share ships unsigned, so a
self-replacing binary that downloads and installs without asking is exactly the
behaviour a user should distrust. The Mac app deliberately does **not** use
Sparkle: Sparkle's value is silent signed installation, which is the part we
cannot do honestly here. If a Developer ID certificate ever appears, revisit —
signed auto-update is a different risk calculation.

### The updater keypair is not a code signing certificate

Tauri refuses to apply an update whose payload is not signed with its own
minisign key. That key is **free** and unrelated to Authenticode or Developer
ID: it proves the update came from this repo's CI, not that Microsoft or Apple
vouches for the app.

* Public key: in `windows/src-tauri/tauri.conf.json`, safe to publish.
* Private key: repository secret `TAURI_SIGNING_PRIVATE_KEY`. It exists only in
  GitHub's encrypted secret store — it is not in the repo and was removed from
  disk after generation.

To rotate it:

```bash
cd windows && npx tauri signer generate -w /tmp/key -p ""
gh secret set TAURI_SIGNING_PRIVATE_KEY < /tmp/key
# put the .pub contents into tauri.conf.json -> plugins.updater.pubkey
rm -P /tmp/key
```

Rotating invalidates updates for anyone still on an older build; they must
download manually once.

### Rollback

There is no in-app downgrade. To roll a bad release back:

1. **Stop the bleeding.** Mark the bad release as a pre-release on GitHub, or
   delete it. `releases/latest` then resolves to the previous good release, and
   `latest.json` with it — so Windows clients stop being offered the bad build
   and the Mac check stops reporting it.
2. **Re-point users.** Anyone already updated installs the previous version from
   its release page. The Windows installer overwrites in place; on macOS, drag
   the older `.app` over the newer one.
3. **Fix forward.** Land the fix, let release-please cut a new version, and
   publish. A version *above* the bad one is the only thing that reaches clients
   automatically — re-publishing the same number will not.

Because artifacts are immutable once attached to a release, the previous build
is always still downloadable at its own release page.

---

## Also not on the Mac App Store

Separate from signing: Display Share uses the private `CGVirtualDisplay` API and
runs unsandboxed with a sibling helper process. App Review rejects private API
use outright, so direct download is the only distribution channel regardless of
certificates.
