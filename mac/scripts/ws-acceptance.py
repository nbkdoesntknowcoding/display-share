#!/usr/bin/env python3
"""Task 2.3 acceptance: a scripted WebSocket client.

Checks the three things the task asks for:
  1. connect and receive a *decodable* stream from the very first frame
  2. a second connection is rejected with a clear error, not silently dropped
  3. reconnect cleanly after an abrupt drop

Deliberately implements the WebSocket handshake and frame parsing by hand so
this test shares no code with the sender - the protocol is verified, not our
own abstraction over it.
"""
import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile

HOST = os.environ.get("DS_HOST", "127.0.0.1")
PORT = int(os.environ.get("DS_WS_PORT", "8788"))
HEADER = 16
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_connect(host, port, timeout=10):
    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.sendall(
        f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n".encode()
    )
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("server closed during handshake")
        buf += chunk
    head, rest = buf.split(b"\r\n\r\n", 1)
    if b"101" not in head.split(b"\r\n")[0]:
        raise RuntimeError(f"bad handshake: {head.decode(errors='replace')[:200]}")
    expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if expected.lower().encode() not in head.lower():
        raise RuntimeError("Sec-WebSocket-Accept mismatch")
    return sock, rest


def ws_send(sock, payload, opcode=0x1):
    """Client frames must be masked (RFC 6455)."""
    header = bytes([0x80 | opcode])
    mask = os.urandom(4)
    n = len(payload)
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 65536:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(header + mask + masked)


def ws_read(sock, buf):
    """Returns (opcode, payload, buf). Reassembles continuation frames."""
    def need(n):
        nonlocal buf
        while len(buf) < n:
            chunk = sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            buf += chunk

    opcode = None
    data = b""
    while True:
        need(2)
        b0, b1 = buf[0], buf[1]
        fin = b0 & 0x80
        op = b0 & 0x0F
        masked = b1 & 0x80
        length = b1 & 0x7F
        offset = 2
        if length == 126:
            need(4)
            length = struct.unpack(">H", buf[2:4])[0]
            offset = 4
        elif length == 127:
            need(10)
            length = struct.unpack(">Q", buf[2:10])[0]
            offset = 10
        if masked:
            need(offset + 4)
            mask = buf[offset:offset + 4]
            offset += 4
        need(offset + length)
        payload = buf[offset:offset + length]
        if masked:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        buf = buf[offset + length:]
        if opcode is None and op != 0:
            opcode = op
        data += payload
        if fin:
            return opcode, data, buf


def parse_video(msg):
    """Parse per protocol/SPEC.md §3."""
    if len(msg) < HEADER:
        raise ValueError(f"short message: {len(msg)}")
    length = struct.unpack(">I", msg[0:4])[0]
    if length != len(msg) - 4:
        raise ValueError(f"length {length} != actual {len(msg) - 4}")
    mtype = msg[4]
    flags = msg[5]
    timestamp = struct.unpack(">Q", msg[8:16])[0]
    return {
        "type": mtype,
        "keyframe": bool(flags & 1),
        "timestamp": timestamp,
        "payload": msg[HEADER:],
    }


passed = failed = 0


def check(label, ok, detail=""):
    global passed, failed
    if ok:
        print(f"  ✅ {label}" + (f" ({detail})" if detail else ""))
        passed += 1
    else:
        print(f"  ❌ {label}" + (f" ({detail})" if detail else ""))
        failed += 1


def collect(seconds=4.0, expect_welcome=True):
    """Connect, say hello, gather frames for a while."""
    sock, buf = ws_connect(HOST, PORT)
    sock.settimeout(seconds)
    ws_send(sock, json.dumps({
        "type": "hello",
        "protocolVersion": 1,
        "client": "ws-acceptance/1.0",
        "receiver": {"width": 1920, "height": 1080, "scale": 1.0, "refreshRate": 60},
    }).encode())

    welcome = None
    frames = []
    import time
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            op, data, buf = ws_read(sock, buf)
        except (socket.timeout, ConnectionError):
            break
        if op == 0x1:
            msg = json.loads(data)
            if msg.get("type") == "welcome":
                welcome = msg
            elif msg.get("type") == "error":
                return sock, welcome, frames, msg
        elif op == 0x2:
            frames.append(parse_video(data))
    return sock, welcome, frames, None


print("=== Task 2.3 — WebSocket transport acceptance ===")
print(f"target ws://{HOST}:{PORT}\n")

# --- 1. connect and receive a decodable stream from the first frame ---------
print("--- 1. first connection ---")
sock1, welcome, frames, err = collect(5.0)
check("handshake completed", True)
check("received welcome", welcome is not None,
      f"v{welcome.get('protocolVersion')} {welcome.get('video', {}).get('width')}x"
      f"{welcome.get('video', {}).get('height')}" if welcome else "none")
check("received video frames", len(frames) > 0, f"{len(frames)} frames")

if frames:
    check("FIRST frame is a keyframe", frames[0]["keyframe"],
          "so the receiver can decode immediately")
    # NALU type is the LOW 5 BITS of the header byte; the upper bits are
    # nal_ref_idc, so an SPS may be 0x67 or 0x27. Comparing the whole byte is
    # the classic way to "not find" a parameter set that is right there.
    p0 = frames[0]["payload"]
    sps_first = p0[:4] == b"\x00\x00\x00\x01" and (p0[4] & 0x1F) == 7
    check("first frame payload starts with SPS", sps_first,
          f"header byte 0x{p0[4]:02x}, type {p0[4] & 0x1F}")
    check("all messages are type 1 (video)", all(f["type"] == 1 for f in frames))
    check("timestamps strictly increase",
          all(b["timestamp"] > a["timestamp"] for a, b in zip(frames, frames[1:])))

    # The real proof: hand the bytes to an independent decoder.
    raw = b"".join(f["payload"] for f in frames)
    with tempfile.NamedTemporaryFile(suffix=".h264", delete=False) as fh:
        fh.write(raw)
        path = fh.name
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "stream=codec_name,width,height,has_b_frames",
         "-of", "default=noprint_wrappers=1", path],
        capture_output=True, text=True)
    decode = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "null", "-"],
                            capture_output=True, text=True)
    info = dict(l.split("=", 1) for l in probe.stdout.strip().splitlines() if "=" in l)
    check("stream is decodable by an independent decoder",
          info.get("codec_name") == "h264" and not decode.stderr.strip(),
          f"{info.get('codec_name')} {info.get('width')}x{info.get('height')}"
          + (f" ffmpeg: {decode.stderr.strip()[:80]}" if decode.stderr.strip() else ""))
    check("no B-frames (WebCodecs low-latency requirement)",
          info.get("has_b_frames") == "0", f"has_b_frames={info.get('has_b_frames')}")
    os.unlink(path)

# --- 2. second connection is rejected with a clear error --------------------
print("\n--- 2. second concurrent connection ---")
try:
    sock2, buf2 = ws_connect(HOST, PORT)
    sock2.settimeout(4)
    op, data, buf2 = ws_read(sock2, buf2)
    msg = json.loads(data) if op == 0x1 else {}
    check("rejected with an explicit error", msg.get("type") == "error",
          f"code={msg.get('code')}")
    check("error code is 'busy'", msg.get("code") == "busy", msg.get("message", ""))
    sock2.close()
except Exception as e:
    check("second connection handled", False, str(e))

# --- 3. reconnect cleanly after an abrupt drop ------------------------------
print("\n--- 3. abrupt drop then reconnect ---")
# SO_LINGER 0 sends RST rather than a clean FIN: a real crash, not a close.
sock1.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
sock1.close()
import time
time.sleep(1.5)

sock3, welcome3, frames3, err3 = collect(5.0)
check("reconnected after abrupt drop", welcome3 is not None)
check("received frames after reconnect", len(frames3) > 0, f"{len(frames3)} frames")
if frames3:
    check("FIRST frame after reconnect is a keyframe", frames3[0]["keyframe"],
          "forced IDR on connect, not waiting for a natural one")
sock3.close()

print(f"\n=== {passed} passed, {failed} failed ===")
sys.exit(1 if failed else 0)
