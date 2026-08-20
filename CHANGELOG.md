# Changelog

## [0.8.0](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.7.4...v0.8.0) (2026-08-20)


### Features

* release the Phase 10 interface, latency and wired-link work ([b9c4b72](https://github.com/nbkdoesntknowcoding/display-share/commit/b9c4b725dc1da34a61d954a612f9d741bda299f8))

## [0.7.4](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.7.3...v0.7.4) (2026-08-19)


### Performance

* measure the latency, then remove the delay that was measurable ([#18](https://github.com/nbkdoesntknowcoding/display-share/issues/18)) ([00e6baf](https://github.com/nbkdoesntknowcoding/display-share/commit/00e6bafc0206e6a08584de9cf6831ccf7b1cf2fb))

## [0.7.3](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.7.2...v0.7.3) (2026-08-19)


### Bug Fixes

* **windows:** show the version, and delete the duplicated share button ([#16](https://github.com/nbkdoesntknowcoding/display-share/issues/16)) ([ba7e9ca](https://github.com/nbkdoesntknowcoding/display-share/commit/ba7e9ca76987e8181997cb4e5a2cb27359e8a8e2))

## [0.7.2](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.7.1...v0.7.2) (2026-08-19)


### Bug Fixes

* **mac:** read GitHub's compare direction the right way round ([#14](https://github.com/nbkdoesntknowcoding/display-share/issues/14)) ([4b2e845](https://github.com/nbkdoesntknowcoding/display-share/commit/4b2e84522213d8576d96f998f348fec0e73321e6))

## [0.7.1](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.7.0...v0.7.1) (2026-08-19)


### Bug Fixes

* **release:** point latest.json at the asset GitHub actually created ([#12](https://github.com/nbkdoesntknowcoding/display-share/issues/12)) ([3c1e49d](https://github.com/nbkdoesntknowcoding/display-share/commit/3c1e49d6f1101b1bf8b9336c0ecaa2c306cc7a93))

## [0.7.0](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.6.0...v0.7.0) (2026-08-19)


### Features

* **mac:** let source installs update themselves once the release contains them ([#10](https://github.com/nbkdoesntknowcoding/display-share/issues/10)) ([bce16a1](https://github.com/nbkdoesntknowcoding/display-share/commit/bce16a14c2eae5e138bdd7af82ec95515bfe5b0a))

## [0.6.0](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.5.0...v0.6.0) (2026-08-19)


### Chores

* release 0.6.0 ([e4c106a](https://github.com/nbkdoesntknowcoding/display-share/commit/e4c106ae5fbdd64bad76f878d01e15d728ac6d9d))

## [0.5.0](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.4.0...v0.5.0) (2026-08-18)


### Features

* **mac:** view and decode a Windows desktop in the Mac app ([#6](https://github.com/nbkdoesntknowcoding/display-share/issues/6)) ([e1cf6e3](https://github.com/nbkdoesntknowcoding/display-share/commit/e1cf6e3a7faf51d2090af4029757ea40caeae7de))

## [0.4.0](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.3.0...v0.4.0) (2026-08-18)


### Features

* **windows:** capture, encode and serve the Windows desktop (Task 8.1) ([#4](https://github.com/nbkdoesntknowcoding/display-share/issues/4)) ([91f02c0](https://github.com/nbkdoesntknowcoding/display-share/commit/91f02c02b8a3328d961418ef84caabcf45ca8f24))

## [0.3.0](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.2.1...v0.3.0) (2026-08-18)


### Features

* **diagnostics:** --out so permissions can be checked under the app's identity ([c1a8009](https://github.com/nbkdoesntknowcoding/display-share/commit/c1a8009859585aa5bcaebe55071cad81dc04c530))
* **input:** let the cursor roam the whole Mac, not just the second screen ([fdc0346](https://github.com/nbkdoesntknowcoding/display-share/commit/fdc0346359c0d7521d1e1b72b5161fa38aa1c681))
* one-command installer and a copy-paste prompt for coding agents ([465b4aa](https://github.com/nbkdoesntknowcoding/display-share/commit/465b4aab2ea49f2ac85bcbd1949b9a6382f9311a))


### Bug Fixes

* **ci:** stop tauri-action eating the .sig files ([e375458](https://github.com/nbkdoesntknowcoding/display-share/commit/e37545878afd0e80eb1773b7add824a1d248a253))
* **input:** drop injected events when the target display is gone ([94cad9d](https://github.com/nbkdoesntknowcoding/display-share/commit/94cad9d70ae4208f42ba914b2d06dceaf396f99b))
* **install:** sign with a stable identifier so macOS permissions stick ([326959e](https://github.com/nbkdoesntknowcoding/display-share/commit/326959e112a408e264deff300cd4aa31a67f8833))
* **install:** sign with a stable local identity so permissions stop resetting ([192e558](https://github.com/nbkdoesntknowcoding/display-share/commit/192e55898dc91fcee7714d11ef899e9008c1a48b))
* **permissions:** detect a grant the running process cannot see ([b6ebffc](https://github.com/nbkdoesntknowcoding/display-share/commit/b6ebffcc8ec5ce5b396387d7d2fe0f40f818f074))
* **permissions:** stop the prompt storm I introduced ([7b4b721](https://github.com/nbkdoesntknowcoding/display-share/commit/7b4b72199f5cbf6d30051c7d45b684f75a6c2e42))
* **receiver:** setStatus was deleting the entire UI ([704763e](https://github.com/nbkdoesntknowcoding/display-share/commit/704763ed579c8b2e6195dd63458471cba458ded4))
* **updater:** enable createUpdaterArtifacts so the .sig is produced ([93a5a29](https://github.com/nbkdoesntknowcoding/display-share/commit/93a5a2992cac9f3f15ff70004ef0128bbc86a2eb))
* **ux:** name the receiver distinctly and explain the two apps up front ([4c0d75b](https://github.com/nbkdoesntknowcoding/display-share/commit/4c0d75b034388eb572ae851d60e345f227cec987))
* **ux:** opening an already-running app showed nothing at all ([ef20cce](https://github.com/nbkdoesntknowcoding/display-share/commit/ef20cced89514b49289609f0ee4ab33b0ee27430))


### Documentation

* input verified on Windows; plan the reverse direction ([49beb6b](https://github.com/nbkdoesntknowcoding/display-share/commit/49beb6be3b7c291320fa766e7e2be8d129e450f5))
* it works on real Windows hardware ([bc5f77e](https://github.com/nbkdoesntknowcoding/display-share/commit/bc5f77e162d7e634311ecb2eb5b4b87371d9a16e))

## [0.2.1](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.2.0...v0.2.1) (2026-08-18)


### Bug Fixes

* **ci:** attach release assets with gh, and use sha256sum on Windows ([eb61265](https://github.com/nbkdoesntknowcoding/display-share/commit/eb61265ec45793035125468e2652e558c0a0bf1a))
* **ci:** check out the release-please tag, not main ([9a84216](https://github.com/nbkdoesntknowcoding/display-share/commit/9a84216d5ae085a405bb66fb5dd84a537c2a2e38))
* **ci:** release-please tags never triggered the build jobs ([a559158](https://github.com/nbkdoesntknowcoding/display-share/commit/a55915811fe91b6f9aca6ee500d6f95ae80780f1))
* **release:** DMG filename and the missing updater manifest ([24c4f27](https://github.com/nbkdoesntknowcoding/display-share/commit/24c4f27dd0514a67d71aa7b5bbefea3922c45564))

## [0.2.0](https://github.com/nbkdoesntknowcoding/display-share/compare/v0.1.0...v0.2.0) (2026-08-17)


### Features

* adaptive bitrate driven by receiver reports ([5992f95](https://github.com/nbkdoesntknowcoding/display-share/commit/5992f952013dcd8c3712712d3c2214f5e6cadf45))
* Bonjour discovery and PIN pairing ([832aff0](https://github.com/nbkdoesntknowcoding/display-share/commit/832aff0efbb874abba48ff258c392fd646c74b74))
* **client:** WebCodecs H.264 viewer, and default to software decode ([0597134](https://github.com/nbkdoesntknowcoding/display-share/commit/0597134ba4f3e9485c38fa609ce3dd8850cff783))
* forward mouse and keyboard input from the receiver ([5189ce9](https://github.com/nbkdoesntknowcoding/display-share/commit/5189ce9484c6f13a62ff25edbc17425e4f5f4330))
* **mac:** capture pipeline and MJPEG server ([4349506](https://github.com/nbkdoesntknowcoding/display-share/commit/4349506b62ed6c9d96f32051b7e0874b9aaca6f1))
* **mac:** CGEvent injection for forwarded input ([f59bbc8](https://github.com/nbkdoesntknowcoding/display-share/commit/f59bbc8c7f1ee1cf063bd69ef033e1b4900ddc89))
* **mac:** first-run onboarding with live permission detection ([effb27d](https://github.com/nbkdoesntknowcoding/display-share/commit/effb27d85a26d4086bcde478c8d333eb051af281))
* **mac:** hardware H.264 encoder via VideoToolbox ([e7ba45d](https://github.com/nbkdoesntknowcoding/display-share/commit/e7ba45d626bcb07edd13be693a259ea36c06d38a))
* **mac:** live resolution, frame rate and quality controls ([0f2b078](https://github.com/nbkdoesntknowcoding/display-share/commit/0f2b078722b71da1796ce44b51f393738107b03b))
* **mac:** scaffold the app, DisplayShareCore and vd_helper subprocess ([ce2108b](https://github.com/nbkdoesntknowcoding/display-share/commit/ce2108b8fc382c1877165c894ff06178cf290842))
* **mac:** session supervisor for sleep/wake, drops and reconfiguration ([0eed7c9](https://github.com/nbkdoesntknowcoding/display-share/commit/0eed7c9b7c96f1fcffbfca8fdd14c733f0c5c1ea))
* **mac:** WebSocket transport carrying H.264 ([9765f37](https://github.com/nbkdoesntknowcoding/display-share/commit/9765f37de87cf7d2a1d64e0cf4b18f7ad3a9b52a))
* **protocol:** wire format spec, implementation and golden vectors ([9ec8987](https://github.com/nbkdoesntknowcoding/display-share/commit/9ec89873ec7f1cab4619680daeaa220ed788cc33))
* **spike:** capture a virtual display with ScreenCaptureKit ([3b7026c](https://github.com/nbkdoesntknowcoding/display-share/commit/3b7026c144edcf42cb15e0d96daf695f5bb249d0))
* **spike:** measure baseline capture cost and record Phase 0 findings ([860c6ab](https://github.com/nbkdoesntknowcoding/display-share/commit/860c6ab609a2566fa02d99623c6df58838b46e1b))
* **spike:** verify CGVirtualDisplay on macOS 26.2 / Apple M4 ([ac3b176](https://github.com/nbkdoesntknowcoding/display-share/commit/ac3b176dbe5ea46e21ddc387e5eb747f1e86e589))
* update checks on both platforms via GitHub Releases ([650b5d5](https://github.com/nbkdoesntknowcoding/display-share/commit/650b5d58f9e1dc4da1037169f75d8fb58cdc1019))
* **windows:** Tauri v2 receiver with WebCodecs decode and panel negotiation ([a4d5d5e](https://github.com/nbkdoesntknowcoding/display-share/commit/a4d5d5e94989fd2b9adbce71155c4c7bd2dc17e4))


### Bug Fixes

* **ci:** workflows failed at startup from `secrets` used in an `if` ([6bb5180](https://github.com/nbkdoesntknowcoding/display-share/commit/6bb51805f823fb109cc887a84c8fa32a6f93f32d))
* **windows:** add the icon set — .ico is required for the Windows build ([8b14a69](https://github.com/nbkdoesntknowcoding/display-share/commit/8b14a691ac71e6f09bc68f6df14cc352456e7937))


### Documentation

* correct README status for Phase 3 ([09a607c](https://github.com/nbkdoesntknowcoding/display-share/commit/09a607c5fd852438d0571f3967faba9c1028a03c))
* correct the README — the Windows installer now builds in CI ([125a780](https://github.com/nbkdoesntknowcoding/display-share/commit/125a7804fc7a2fca80768954ca7d54c1f90d6674))
* fix stale .release path after the dist/ rename ([7821ba0](https://github.com/nbkdoesntknowcoding/display-share/commit/7821ba0bce911c0c9dc76ff32aaaba20e7bdb1fe))
* GPL-3.0 licence, README, contributing guide; updates via GitHub Releases ([dfed625](https://github.com/nbkdoesntknowcoding/display-share/commit/dfed625b7e3473400145b979d3a6099ee4105d4a))
* README for Phase 4 ([aa8463b](https://github.com/nbkdoesntknowcoding/display-share/commit/aa8463b0359a56088cf0e98bbadf6002d399943a))
* README for Phase 5 ([278df6b](https://github.com/nbkdoesntknowcoding/display-share/commit/278df6b57a941e5b1f26d92545181f1c9123358a))
* README for Phase 6 packaging status ([51d7a60](https://github.com/nbkdoesntknowcoding/display-share/commit/51d7a6063cd1edc340f111f684954076ab4e2b94))
* unsigned open-source distribution, and stop gating CI on signatures ([8b3f8f2](https://github.com/nbkdoesntknowcoding/display-share/commit/8b3f8f2ed7b599c1cb3c0aa66b824a5167578cf9))


### Build & Packaging

* macOS packaging pipeline and CI for both platforms ([dd502d1](https://github.com/nbkdoesntknowcoding/display-share/commit/dd502d1b55f1903a4f34ffb61d4ce5db9b35f41a))
* tag-triggered release pipeline with release-please ([4441a98](https://github.com/nbkdoesntknowcoding/display-share/commit/4441a98d94f763ad5e3434203eb302eb093feab0))
