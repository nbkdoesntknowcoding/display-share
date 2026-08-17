#!/usr/bin/env python3
"""Task 5.1 acceptance: forwarded input arrives in order with timestamps.

Acceptance for 5.1 is explicitly "verified by logging only" - no injection yet.
Also checks the SPEC §4.10 safety rule: input from an UNAUTHORISED receiver must
be ignored, since injection can drive any app on the Mac.
"""
import json, os, re, socket, struct, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ns = {}
exec(open(os.path.join(HERE, "ws-acceptance.py")).read().split("passed = failed = 0")[0], ns)
ws_connect, ws_send, ws_read = ns["ws_connect"], ns["ws_send"], ns["ws_read"]

HOST, PORT = os.environ.get("DS_HOST", "127.0.0.1"), int(os.environ.get("DS_WS_PORT", "8788"))
LOG = os.environ.get("DS_LOG", "/tmp/ds-app.log")
passed = failed = 0

def check(label, ok, detail=""):
    global passed, failed
    if ok: print(f"  ✅ {label}" + (f" ({detail})" if detail else "")); passed += 1
    else:  print(f"  ❌ {label}" + (f" ({detail})" if detail else "")); failed += 1

def logtext():
    return open(LOG).read()

print("=== Task 5.1 — input capture / forwarding acceptance ===\n")

# --- 1. unauthorised input must be ignored ---------------------------------
print("--- 1. input from an UNPAIRED receiver ---")
before = logtext().count("[DisplayShare] input:")
s0, b0 = ws_connect(HOST, PORT); s0.settimeout(2)
ws_send(s0, json.dumps({"type": "hello", "protocolVersion": 1, "client": "rogue/1.0",
    "deviceId": "rogue-device", "deviceName": "Rogue",
    "receiver": {"width": 1920, "height": 1080, "scale": 1.0, "refreshRate": 60}}).encode())
time.sleep(1)
ws_send(s0, json.dumps({"type": "input", "events": [
    {"k": "move", "x": 0.5, "y": 0.5, "t": 1},
    {"k": "down", "b": 0, "t": 2}]}).encode())
time.sleep(1.5)
after = logtext().count("[DisplayShare] input:")
check("no input accepted from unpaired receiver", after == before, f"{after - before} logged")
check("refusal is logged", "unauthorised receiver" in logtext())
s0.close(); time.sleep(1)

# --- 2. pair, then forward a realistic batch -------------------------------
print("\n--- 2. authorised receiver forwards input ---")
s, buf = ws_connect(HOST, PORT); s.settimeout(3)
ws_send(s, json.dumps({"type": "hello", "protocolVersion": 1, "client": "input-acc/1.0",
    "deviceId": "input-device", "deviceName": "InputTest",
    "receiver": {"width": 1920, "height": 1080, "scale": 1.0, "refreshRate": 60}}).encode())

def pump(seconds=2.0):
    global buf
    deadline = time.time() + seconds
    while time.time() < deadline:
        try: op, data, buf = ws_read(s, buf)
        except Exception: break
        if op == 0x1:
            m = json.loads(data)
            if m.get("code") == "pairing_required":
                pins = re.findall(r"PIN (\d{4})", logtext())
                if pins:
                    ws_send(s, json.dumps({"type": "pair", "pin": pins[-1],
                        "deviceId": "input-device", "deviceName": "InputTest"}).encode())
pump(3)

mark = logtext().count("[DisplayShare] input:")
# A realistic sequence: drag, scroll, and cmd+A.
batch = [
    {"k": "move", "x": 0.10, "y": 0.10, "t": 100},
    {"k": "move", "x": 0.25, "y": 0.30, "t": 116},
    {"k": "down", "b": 0, "t": 130},
    {"k": "move", "x": 0.60, "y": 0.55, "t": 150},
    {"k": "up", "b": 0, "t": 180},
    {"k": "scroll", "dx": 0, "dy": -3, "t": 200},
    {"k": "key", "code": "KeyA", "down": True,
     "mods": {"shift": False, "ctrl": False, "alt": False, "meta": True}, "t": 220},
    {"k": "key", "code": "KeyA", "down": False,
     "mods": {"shift": False, "ctrl": False, "alt": False, "meta": True}, "t": 240},
]
ws_send(s, json.dumps({"type": "input", "events": batch}).encode())
time.sleep(2)

log = logtext()
lines = [l for l in log.splitlines() if "[DisplayShare] input:" in l][mark:]
check("events reached the Mac", len(lines) >= len(batch), f"{len(lines)} logged, {len(batch)} sent")
check("move logged with coordinates", any("move  x=0.1000 y=0.1000" in l for l in lines))
check("button down logged", any("down  button=0" in l for l in lines))
check("button up logged", any("up  button=0" in l for l in lines))
check("scroll logged with deltas", any("scroll dx=0.00 dy=-3.00" in l for l in lines))
check("key logged with modifier", any("key   KeyA down [cmd]" in l for l in lines))
check("every event carries a timestamp", all("t=" in l for l in lines))

# Order must be preserved as sent.
stamps = [int(m.group(1)) for l in lines for m in [re.search(r"t=(\d+)", l)] if m]
check("timestamps are non-decreasing (order preserved)",
      stamps == sorted(stamps), f"{stamps}")

# --- 3. malformed input is rejected at the boundary ------------------------
print("\n--- 3. malformed input ---")
mark2 = logtext().count("[DisplayShare] input:")
ws_send(s, json.dumps({"type": "input", "events": [
    {"k": "move", "x": 1.9, "y": 0.5, "t": 300},     # out of range
    {"k": "move", "x": -0.4, "y": 0.5, "t": 310},    # out of range
    {"k": "move", "x": 0.5, "y": 0.5, "t": 5},       # out of order
    {"k": "move", "x": 0.4, "y": 0.4, "t": 400},     # valid
]}).encode())
time.sleep(2)
new = [l for l in logtext().splitlines() if "[DisplayShare] input:" in l][mark2:]
check("out-of-range moves dropped", sum("out-of-range" in l for l in new) == 2,
      f"{sum('out-of-range' in l for l in new)} dropped")
check("out-of-order event dropped", any("out-of-order" in l for l in new))
check("the valid move still got through", any("move  x=0.4000" in l for l in new))

s.close()
print(f"\n=== {passed} passed, {failed} failed ===")
sys.exit(1 if failed else 0)
