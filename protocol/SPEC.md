# Display Share Wire Protocol

**Version 1** · Status: active · Last updated 17 Aug 2026

This document is normative. The Windows receiver is written from this document
alone; if something is ambiguous here, that is a bug in this document.

---

## 1. Transport

A single **WebSocket** connection carries everything.

| | |
|---|---|
| WebSocket port | `8788` |
| Endpoint | `ws://<sender-host>:8788` |
| Viewer page (dev) | `http://<sender-host>:8787/` |
| Binary messages | video access units (§3) |
| Text messages | JSON control channel (§4) |

### 1.1 The reverse direction

A Windows machine sharing **its** screen to a Mac uses the same framing, the same
control channel and the same pairing, with the roles swapped — the message
formats are direction-agnostic and are deliberately NOT forked, so there is one
specification to keep correct rather than two.

| | |
|---|---|
| WebSocket port | `7879` |
| Endpoint | `ws://<windows-host>:7879` |

The port is separate from `8787`/`8788` so a single machine can hold both roles
without a clash.

The video/control socket and the development viewer page are on **separate
ports** because `NWProtocolWebSocket` performs the upgrade handshake for every
connection on its listener, so a plain HTTP GET cannot share that port. The
viewer page exists only for browser testing; the shipping Windows receiver
connects straight to the WebSocket and never fetches it.

WebSocket was chosen over WebRTC because on a LAN, WebRTC's real benefit —
congestion-controlled UDP — buys little while costing an entire signalling and
ICE state machine. It was chosen over raw TCP because browsers and WebView2 can
speak it natively.

**One client at a time.** The sender accepts a single active receiver. A second
connection attempt is accepted, sent an `error` with code `busy`, and closed
(§4.7). This keeps the encoder pinned to one output geometry; multiple
simultaneous receivers are explicitly out of scope for v1.

---

## 2. Versioning

The client sends `hello` with `protocolVersion` as its first message. The server
replies `welcome` carrying its own `protocolVersion`.

* If the versions match, the session proceeds.
* If they differ, the server MAY still proceed when it can serve the client's
  version; otherwise it sends `error` with code `unsupported_version` and closes.
* A client MUST NOT send any other message before `hello`.
* A client MUST NOT assume video will not arrive before it has processed
  `welcome` — the server is permitted to start sending immediately.

Version 1 is the only defined version. Bump it for any change to §3's header
layout or any removal of a §4 field; adding an optional JSON field is not a
breaking change and does not require a bump.

---

## 3. Binary messages — video

Every binary WebSocket message is exactly one **access unit** (one decodable
picture) with a 16-byte header:

```
 offset  size  type        field
 ------  ----  ----------  -----------------------------------------------
      0     4  uint32 BE   length      bytes following this field (12 + payload)
      4     1  uint8       type        1 = video access unit
      5     1  uint8       flags       bit0 = keyframe (IDR). Other bits reserved, 0.
      6     2  uint16 BE   reserved    0
      8     8  uint64 BE   timestamp   capture time, microseconds (§3.2)
     16     n  bytes       payload     Annex-B elementary stream
```

All multi-byte integers are **big-endian** (network byte order).

> **Why a length prefix when WebSocket already frames messages?** So the exact
> same framing works unchanged over raw TCP, which is the fallback if a future
> receiver cannot use WebSocket. Readers over WebSocket MAY treat `length` as a
> consistency check rather than a parsing necessity, but MUST reject a message
> whose `length` does not equal `actualMessageSize - 4`.

### 3.1 Payload format

The payload is **Annex-B**: NALUs prefixed with the 4-byte start code
`00 00 00 01`.

* When `flags & 0x01` (keyframe) is set, the payload **begins with SPS and PPS**,
  followed by the IDR slice. Parameter sets are repeated in-band ahead of every
  keyframe, so a receiver that connects mid-stream needs no side channel.
* Non-keyframe payloads contain only slice NALUs.
* The stream contains **no B-frames**. `AllowFrameReordering` is disabled on the
  encoder, so decode order equals presentation order and a decoder may emit each
  frame as soon as it is decoded.

> **Decoder configuration — the single most common integration bug.**
> `VideoDecoder.configure()` MUST be called **without** a `description` field.
> Supplying `description` puts WebCodecs into AVCC mode, where it expects
> length-prefixed NALUs, and decoding then fails *silently* against this
> Annex-B stream. Derive the codec string from the SPS instead (§3.3).

### 3.2 Timestamps

`timestamp` is microseconds from an arbitrary sender-side monotonic origin. It is
**not** wall-clock time and MUST NOT be compared against the receiver's clock in
absolute terms. Its purposes are:

1. ordering and duplicate detection;
2. computing *relative* end-to-end latency, by echoing the value back in `stats`
   (§4.6) so the sender can measure a round trip against its own clock.

### 3.3 Deriving the codec string

WebCodecs needs a codec string such as `avc1.640028`. Read it from the SPS NALU
(type 7) in the first keyframe payload:

```
avc1.PPCCLL
   PP = profile_idc      SPS byte 1  (hex)
   CC = constraint flags SPS byte 2  (hex)
   LL = level_idc        SPS byte 3  (hex)
```

where "SPS byte 0" is the NALU header byte immediately after the start code.

**Locate the SPS by its type, not by a literal byte.** The NALU type is the
**low 5 bits** of that header byte; the upper bits are `nal_ref_idc`. An SPS is
therefore `0x67` *or* `0x27` (both have type 7) depending on the encoder's
reference marking — VideoToolbox on macOS 26 emits `0x27`. Test
`(byte & 0x1F) == 7`; comparing the whole byte is a reliable way to miss a
parameter set that is right there.

Example: `27 64 00 28 …` → `avc1.640028` (High profile, level 4.0).

---

## 4. Text messages — control channel

Every text message is a JSON object with a `type` field. Unknown `type` values
MUST be ignored rather than treated as errors, so either side can add messages
without a version bump.

### 4.1 `hello` — client → server (required, first)

```json
{
  "type": "hello",
  "protocolVersion": 1,
  "client": "display-share-windows/0.1.0",
  "receiver": {
    "width": 1920,
    "height": 1080,
    "scale": 1.0,
    "refreshRate": 60
  }
}
```

`receiver` describes the physical panel in **pixels**. The sender uses it to size
the virtual display so the image is not letterboxed or stretched (Task 3.3).
`scale` is the OS display scaling factor (1.0, 1.25, 1.5, 2.0 …).

### 4.2 `welcome` — server → client

```json
{
  "type": "welcome",
  "protocolVersion": 1,
  "video": { "codec": "h264", "width": 1920, "height": 1080, "fps": 60 },
  "sender": "display-share-mac/0.1.0"
}
```

Sent once, immediately after a successful `hello`. `video.width`/`height` are the
encoded pixel dimensions, which may differ from what the client requested if the
sender could not honour it.

### 4.3 `resize` — client → server

```json
{ "type": "resize", "width": 1280, "height": 720 }
```

Requests a new encoded geometry. The sender applies the mode to the **existing**
virtual display rather than recreating it, so the user's window arrangement
survives. The sender replies with `video_format` (§4.4) on success, or `error`
with code `resize_rejected`.

### 4.4 `video_format` — server → client

```json
{ "type": "video_format", "codec": "h264", "width": 1280, "height": 720, "fps": 60 }
```

Sent whenever the encoded geometry changes. The receiver MUST reconfigure its
decoder on receipt. The sender MUST send a keyframe as the first access unit
after this message.

### 4.5 `request_keyframe` — client → server

```json
{ "type": "request_keyframe" }
```

Asks for an immediate IDR. Sent on decoder error, on first connect if the client
missed the initial keyframe, or after a visible corruption. The sender SHOULD
rate-limit this to at most one forced IDR per 250 ms.

### 4.6 `stats` — client → server

```json
{
  "type": "stats",
  "decodedFrames": 1804,
  "droppedFrames": 12,
  "decodeMillis": 2.4,
  "queuedFrames": 1,
  "lastTimestamp": 123456789
}
```

Sent about once per second. `lastTimestamp` echoes §3.2 from the most recently
*rendered* frame, which lets the sender compute end-to-end latency against its
own clock without the two machines sharing one. Drives adaptive bitrate (Task 4.3).

### 4.7 `pair` — client → server

```json
{ "type": "pair", "pin": "4821", "deviceId": "a3f1…", "deviceName": "VIVOBOOK" }
```

Sent when the sender has replied `error` with code `pairing_required`. `deviceId`
is a stable random identifier the receiver generates once and keeps; `pin` is the
4-digit code the sender is displaying.

On success the sender replies `paired` and the session continues from `hello`
(the client re-sends it). On failure it replies `error` with code `pair_rejected`
and closes. The sender MUST rate-limit attempts — three failures per minute per
device — so the 4-digit space cannot be brute-forced.

### 4.8 `paired` — server → client

```json
{ "type": "paired", "token": "…", "sender": "Nischay's Mac mini" }
```

The receiver stores `token` and presents it in future `hello` messages, making
subsequent connections one click. A token is bound to the `deviceId` that earned
it.

### 4.9 `hello` with a stored token

A paired receiver includes its identity in `hello`:

```json
{ "type": "hello", "protocolVersion": 1, "deviceId": "a3f1…", "token": "…", "receiver": { … } }
```

If `token` is valid for `deviceId`, the sender proceeds straight to `welcome`.
Otherwise it replies `error` / `pairing_required` and shows a PIN.

### 4.10 `input` — client → server

Forwarded mouse and keyboard events, **batched**:

```json
{
  "type": "input",
  "events": [
    { "k": "move",   "x": 0.5123, "y": 0.2341, "t": 1284 },
    { "k": "down",   "b": 0,                    "t": 1290 },
    { "k": "up",     "b": 0,                    "t": 1361 },
    { "k": "scroll", "dx": 0, "dy": -3,         "t": 1400 },
    { "k": "key",    "code": "KeyA", "down": true,
      "mods": { "shift": false, "ctrl": false, "alt": false, "meta": true },
      "t": 1450 }
  ]
}
```

Batching is required, not cosmetic: a 60 Hz mouse produces 60 messages/second per
axis of motion, and one WebSocket text frame each would compete with video for
the same socket. The receiver SHOULD flush at most once per animation frame, and
MUST preserve event order within and across batches.

`t` is milliseconds from an arbitrary receiver-side origin, used only to preserve
ordering and to measure intra-batch spacing. It is **not** comparable to §3.2
timestamps, which come from the sender's clock.

#### Two pointer modes

`move` carries an ABSOLUTE position inside the second screen. That is the normal
mode and it cannot leave that display.

`moverel` carries a RELATIVE delta in device pixels and is used when the pointer
escapes the second screen to roam the rest of the desktop:

```json
{ "k": "moverel", "dx": -12, "dy": 3, "t": 1500 }
```

The receiver switches modes on its own. When the pointer is against an edge of
the video and still being pushed outward, it takes a pointer lock and starts
sending `moverel`. Absolute coordinates cannot express this: the OS clamps the
real pointer at the screen edge, so `x` simply pins at 1.0 and the intent to
keep moving is invisible. A pointer lock is the only way to see continued
motion once the cursor has nowhere left to go.

The sender applies each delta to the current cursor position and **clamps to the
union of all displays**, so the pointer can reach any screen but never leaves the
desktop.

When the resulting position lands back inside the second screen, the sender
sends `pointer_release` (§4.12) and the receiver drops the lock and resumes
absolute `move`. Handing control back automatically matters: a pointer lock the
user cannot escape is a trap.

#### Coordinates

`x` and `y` are **normalised 0.0–1.0 within the displayed video rectangle**, not
the window. The receiver letterboxes the video when its window aspect differs
from the stream, so window-relative coordinates would land in the wrong place;
normalising against the video rect makes the mapping correct regardless of window
size, scaling or letterboxing. Values outside 0–1 mean the pointer left the video
area and MUST be dropped by the receiver rather than clamped.

#### Keys

`code` is the **physical** key identifier from the DOM `KeyboardEvent.code`
(`"KeyA"`, `"Digit1"`, `"ArrowLeft"`, `"Enter"`). Physical rather than logical, so
the sender maps to a macOS virtual keycode without needing to know the receiver's
keyboard layout. `mods` carries the modifier state at the time of the event, since
a modifier may be held from before forwarding was enabled.

Buttons: `0` left, `1` middle, `2` right.

#### Safety

The sender MUST ignore `input` from a receiver that has not completed the
handshake and pairing (§4.9). Input injection is a far stronger capability than
screen viewing — it can drive any application on the Mac — so it is gated on the
same authorisation and additionally requires macOS Accessibility permission,
which the user grants explicitly.

### 4.11 `pointer_release` — server → client

```json
{ "type": "pointer_release" }
```

Sent when a relative-mode pointer returns inside the second screen. The receiver
MUST exit pointer lock and resume sending absolute `move` events. Without this
the user would be stuck in relative mode with no way back.

### 4.12 `error` — server → client

```json
{ "type": "error", "code": "busy", "message": "another receiver is connected" }
```

| Code | Meaning |
|---|---|
| `busy` | another receiver is already connected; this connection is closed |
| `unsupported_version` | the client's `protocolVersion` cannot be served |
| `resize_rejected` | the requested geometry could not be applied |
| `capture_unavailable` | the sender cannot capture (e.g. permission not granted) |
| `pairing_required` | this receiver is not paired; the sender is showing a PIN |
| `pair_rejected` | wrong PIN, or too many attempts |
| `input_unavailable` | input was forwarded but macOS Accessibility permission is not granted |
| `internal` | anything else; `message` carries detail |

---

## 4a. Discovery

The sender advertises itself over Bonjour/mDNS so the receiver never needs an IP
address typed in:

| | |
|---|---|
| Service type | `_displayshare._tcp` |
| Port | the WebSocket port (8788) |
| TXT `v` | protocol version |
| TXT `name` | human-readable sender name |
| TXT `pair` | `required` when the sender expects pairing |

A receiver browses the service, shows the discovered senders, and connects to the
chosen one's resolved address and port. Manual entry stays available for networks
where mDNS is blocked.

The reverse direction advertises under a **different service type**:

| | |
|---|---|
| Service type | `_dsreverse._tcp` |
| Port | `7879` |
| TXT `v` | protocol version |
| TXT `platform` | `windows` |

> **Why not reuse `_displayshare._tcp`?** Because both roles browse on the same
> network. If a Windows machine sharing its screen advertised the same type a Mac
> sender does, the Windows receiver would list other Windows machines as senders
> and the Mac viewer would list itself. The name is also kept to nine characters:
> DNS-SD caps a service name at fifteen.

---

## 5. Session lifecycle

```
client                                   server
  |-- WebSocket connect ------------------->|
  |-- hello ------------------------------->|
  |<------------------------------- welcome |
  |<-------------- binary: keyframe (SPS/PPS+IDR)
  |<-------------- binary: delta frames …   |
  |-- stats (every ~1s) ------------------->|
  |-- request_keyframe (on decode error) -->|
  |<-------------- binary: keyframe         |
  |-- resize ------------------------------>|
  |<-------------------------- video_format |
  |<-------------- binary: keyframe         |
```

On connect the sender MUST force an IDR so the receiver can begin decoding
immediately rather than waiting up to `MaxKeyFrameInterval` for a natural one.

On disconnect the sender stops encoding but leaves the virtual display in place;
display lifecycle is owned by `vd_helper` and is independent of any receiver.

---

## 6. Test vectors

`protocol/vectors/` contains golden binaries so both ends can be tested without
each other. `manifest.json` lists each vector with its expected parse result.

| Vector | What it covers |
|---|---|
| `keyframe.bin` | keyframe flag set, payload starts with SPS then PPS then IDR |
| `delta.bin` | non-keyframe, single slice NALU |
| `empty-payload.bin` | zero-length payload — MUST be rejected |
| `truncated-header.bin` | 9-byte message — MUST be rejected |
| `bad-length.bin` | `length` disagrees with actual size — MUST be rejected |
| `max-timestamp.bin` | `timestamp` = 2^64-1, checks unsigned 64-bit handling |

A conforming parser MUST accept the first two and reject the rest.
