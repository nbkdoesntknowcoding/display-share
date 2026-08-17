#!/usr/bin/env python3
"""Task 5.2 acceptance: injected input actually moves and clicks on the Mac.

Verifies against the REAL cursor: sends a normalised coordinate, reads back the
system cursor position, and checks it landed inside the virtual display's bounds
at the expected point. Restores the original cursor position afterwards.

Requires Accessibility permission for DisplayShare.app. Without it macOS silently
discards posted events, so the test reports that distinctly rather than as a
mapping failure.
"""
import json, os, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ns = {}
exec(open(os.path.join(HERE, "ws-acceptance.py")).read().split("passed = failed = 0")[0], ns)
ws_connect, ws_send, ws_read = ns["ws_connect"], ns["ws_send"], ns["ws_read"]

HOST, PORT = os.environ.get("DS_HOST", "127.0.0.1"), int(os.environ.get("DS_WS_PORT", "8788"))
LOG = os.environ.get("DS_LOG", "/tmp/ds-app.log")
VDSPIKE = "/Users/nischaybk/Projects/Display Share/mac/spike/.build/debug/vdspike"
CURSOR = "/tmp/dscursor"
passed = failed = skipped = 0

def check(label, ok, detail=""):
    global passed, failed
    if ok: print(f"  ✅ {label}" + (f" ({detail})" if detail else "")); passed += 1
    else:  print(f"  ❌ {label}" + (f" ({detail})" if detail else "")); failed += 1

def cursor():
    out = subprocess.run([CURSOR], capture_output=True, text=True).stdout.split()
    return (float(out[0]), float(out[1])) if len(out) == 2 else (0.0, 0.0)

def set_cursor(x, y):
    subprocess.run([CURSOR, "set", str(x), str(y)], capture_output=True)

def vd_bounds():
    """Virtual display bounds in points: (origin_x, origin_y, width, height)."""
    out = subprocess.run([VDSPIKE, "list"], capture_output=True, text=True).stdout
    for line in out.strip().splitlines():
        f = line.split()
        if len(f) >= 8 and f[1] == "0x444d":
            return int(f[6]), int(f[7]), int(f[2]), int(f[3])
    return None

print("=== Task 5.2 — CGEvent injection acceptance ===\n")

original = cursor()
print(f"cursor before: {original}")
size = vd_bounds()
if not size:
    print("❌ no virtual display found"); sys.exit(1)
ox, oy, vw, vh = size
print(f"virtual display: {vw}x{vh} at origin ({ox}, {oy})")

def expected(nx, ny):
    """The exact global point the injector should produce."""
    return (ox + nx * vw, oy + ny * vh)

# Connect + pair.
s, buf = ws_connect(HOST, PORT); s.settimeout(3)
ws_send(s, json.dumps({"type": "hello", "protocolVersion": 1, "client": "inject/1.0",
    "deviceId": "inject-device", "deviceName": "InjectTest",
    "receiver": {"width": vw, "height": vh, "scale": 1.0, "refreshRate": 60}}).encode())

unavailable = False
def pump(seconds=2.0):
    global buf, unavailable
    deadline = time.time() + seconds
    while time.time() < deadline:
        try: op, data, buf = ws_read(s, buf)
        except Exception: break
        if op == 0x1:
            m = json.loads(data)
            if m.get("code") == "pairing_required":
                pins = re.findall(r"PIN (\d{4})", open(LOG).read())
                if pins:
                    ws_send(s, json.dumps({"type": "pair", "pin": pins[-1],
                        "deviceId": "inject-device", "deviceName": "InjectTest"}).encode())
            elif m.get("code") == "input_unavailable":
                unavailable = True
pump(3)

def send_input(events):
    ws_send(s, json.dumps({"type": "input", "events": events}).encode())

t = [0]
def stamp():
    t[0] += 20
    return t[0]

# --- move to the centre of the virtual display -----------------------------
print("\n--- pointer mapping ---")
send_input([{"k": "move", "x": 0.5, "y": 0.5, "t": stamp()}])
pump(1.5)

if unavailable:
    print("\n  ⚠️  SKIPPED: DisplayShare.app lacks Accessibility permission.")
    print("      macOS silently discards posted events without it, so injection")
    print("      cannot be verified. The sender correctly reported")
    print("      `input_unavailable` rather than accepting input and doing nothing.")
    check("graceful degradation: sender reports input_unavailable", True)
    print(f"\n=== {passed} passed, {failed} failed, injection UNVERIFIED (needs permission) ===")
    sys.exit(0)

after = cursor()
want = expected(0.5, 0.5)
print(f"cursor after centre move: {after}, expected {want}")
check("cursor moved from its original position", after != original, f"{original} -> {after}")
# EXACT, on both axes. x is the one that breaks if the display's negative origin
# is ignored, so a loose assertion here would hide the most likely bug.
check("centre maps exactly on x", abs(after[0] - want[0]) <= 1, f"got {after[0]}, want {want[0]}")
check("centre maps exactly on y", abs(after[1] - want[1]) <= 1, f"got {after[1]}, want {want[1]}")

# --- corners ---------------------------------------------------------------
print("\n--- corner accuracy ---")
for label, nx, ny in [("top-left", 0.0, 0.0), ("bottom-right", 1.0, 1.0),
                      ("quarter", 0.25, 0.75)]:
    send_input([{"k": "move", "x": nx, "y": ny, "t": stamp()}])
    pump(1.2)
    pos = cursor()
    want = expected(nx, ny)
    check(f"{label}: exact on both axes",
          abs(pos[0] - want[0]) <= 1 and abs(pos[1] - want[1]) <= 1,
          f"got ({pos[0]:.0f}, {pos[1]:.0f}), want ({want[0]:.0f}, {want[1]:.0f})")

# --- click, drag, scroll, key ---------------------------------------------
print("\n--- click / drag / scroll / key reach the Mac ---")
mark = len([l for l in open(LOG).read().splitlines() if "input:" in l])
send_input([
    {"k": "move", "x": 0.4, "y": 0.4, "t": stamp()},
    {"k": "down", "b": 0, "t": stamp()},
    {"k": "move", "x": 0.6, "y": 0.6, "t": stamp()},   # drag
    {"k": "up", "b": 0, "t": stamp()},
    {"k": "scroll", "dx": 0, "dy": -2, "t": stamp()},
    {"k": "key", "code": "ShiftLeft", "down": True,
     "mods": {"shift": True, "ctrl": False, "alt": False, "meta": False}, "t": stamp()},
    {"k": "key", "code": "ShiftLeft", "down": False,
     "mods": {"shift": False, "ctrl": False, "alt": False, "meta": False}, "t": stamp()},
])
pump(2)
lines = [l for l in open(LOG).read().splitlines() if "input:" in l][mark:]
accepted = [l for l in lines if "DROP" not in l]
dropped = [l for l in lines if "DROP" in l]
check("all 7 events accepted (not merely logged)", len(accepted) >= 7,
      f"{len(accepted)} accepted, {len(dropped)} dropped")
check("drag produced a move while button held", any("move  x=0.6000" in l for l in lines))
check("no unmapped keys", not any("unmapped" in l.lower() for l in lines))

s.close()
set_cursor(*original)
print(f"\ncursor restored to {cursor()}")
print(f"\n=== {passed} passed, {failed} failed ===")
sys.exit(1 if failed else 0)
