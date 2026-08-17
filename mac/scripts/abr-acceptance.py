#!/usr/bin/env python3
"""Task 4.3 acceptance: adaptive bitrate, end to end.

Congesting a real 2.4 GHz link is not reproducible here, so this drives the
control loop through its actual input - the receiver's `stats` messages on the
live control channel - and checks the sender responds at the encoder.

What this proves: the loop is wired, reacts to sustained congestion, recovers on
a clean run, and the stream never stalls while it happens.
What it does not prove: behaviour under real RF congestion on the Vivobook.
"""
import json, os, re, socket, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ns = {}
exec(open(os.path.join(HERE, "ws-acceptance.py")).read().split("passed = failed = 0")[0], ns)
ws_connect, ws_send, ws_read, parse_video = ns["ws_connect"], ns["ws_send"], ns["ws_read"], ns["parse_video"]

HOST, PORT = os.environ.get("DS_HOST", "127.0.0.1"), int(os.environ.get("DS_WS_PORT", "8788"))
LOG = os.environ.get("DS_LOG", "/tmp/ds-app.log")
passed = failed = 0

def check(label, ok, detail=""):
    global passed, failed
    if ok: print(f"  ✅ {label}" + (f" ({detail})" if detail else "")); passed += 1
    else:  print(f"  ❌ {label}" + (f" ({detail})" if detail else "")); failed += 1

def bitrates():
    return [float(m) for m in re.findall(r"bitrate -> ([0-9.]+) Mbps", open(LOG).read())]

sock, buf = ws_connect(HOST, PORT)
sock.settimeout(2)
ws_send(sock, json.dumps({"type": "hello", "protocolVersion": 1, "client": "abr/1.0",
    "deviceId": "abr-device", "deviceName": "ABR",
    "receiver": {"width": 1920, "height": 1080, "scale": 1.0, "refreshRate": 60}}).encode())

frames = 0
last_ts = 0
def pump(seconds):
    """Reads for a while so video keeps flowing and control replies are seen."""
    global buf, frames, last_ts
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            op, data, buf = ws_read(sock, buf)
        except Exception:
            break
        if op == 0x2:
            frames += 1
            # Echo back a timestamp the SENDER minted, exactly as a real receiver
            # does — the sender's clock, not ours (SPEC §3.2).
            globals()["last_ts"] = parse_video(data)["timestamp"]
        elif op == 0x1:
            msg = json.loads(data)
            if msg.get("code") == "pairing_required":
                pins = re.findall(r"PIN (\d{4})", open(LOG).read())
                if pins:
                    ws_send(sock, json.dumps({"type": "pair", "pin": pins[-1],
                        "deviceId": "abr-device", "deviceName": "ABR"}).encode())

print("=== Task 4.3 — adaptive bitrate acceptance ===\n")
pump(4)
check("streaming before congestion", frames > 0, f"{frames} frames")
start_changes = len(bitrates())

print("\n--- sustained congestion reported by the receiver ---")
# Heavy receiver-side loss, reported the way a real receiver would.
decoded, dropped = 1000, 400
for _ in range(10):
    ws_send(sock, json.dumps({"type": "stats", "decodedFrames": decoded,
        "droppedFrames": dropped, "decodeMillis": 40.0, "queuedFrames": 6,
        # Deliberately stale echo: simulates a laggy receiver.
        "lastTimestamp": max(0, last_ts - 400_000)}).encode())
    decoded += 100; dropped += 60
    pump(1.2)

after_congestion = bitrates()
check("bitrate was reduced", len(after_congestion) > start_changes,
      f"{after_congestion[start_changes:] if after_congestion else 'no change'}")
if len(after_congestion) > start_changes:
    seq = after_congestion[start_changes:]
    check("changes were downward", seq[-1] < 12.0, f"{seq[0]} -> {seq[-1]} Mbps")
    check("floor respected (>= 1.5 Mbps)", min(seq) >= 1.5, f"min {min(seq)} Mbps")

before_frames = frames
pump(3)
check("stream never stalled during adaptation", frames > before_frames,
      f"+{frames - before_frames} frames")

print("\n--- link clears ---")
mid = len(bitrates())
# A clean run: no new drops, low decode time.
for _ in range(14):
    ws_send(sock, json.dumps({"type": "stats", "decodedFrames": decoded,
        "droppedFrames": dropped, "decodeMillis": 2.0, "queuedFrames": 0,
        # Fresh echo: a healthy receiver keeping up.
        "lastTimestamp": last_ts}).encode())
    decoded += 100
    pump(1.0)

recovered = bitrates()
check("bitrate recovered upward once clear", len(recovered) > mid and recovered[-1] > recovered[mid - 1] if mid > 0 else len(recovered) > mid,
      f"{recovered[mid-1] if mid > 0 else '?'} -> {recovered[-1] if recovered else '?'} Mbps")

sock.close()
print(f"\n=== {passed} passed, {failed} failed ===")
sys.exit(1 if failed else 0)
