# Changelog

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
