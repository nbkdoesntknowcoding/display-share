#!/usr/bin/env python3
"""Task 4.1 acceptance: discovery and PIN pairing.

Verifies, against the running sender:
  1. an unpaired receiver is refused with `pairing_required`, not silently starved
  2. a wrong PIN is rejected
  3. the correct PIN pairs and the session resumes to `welcome` + video
  4. the issued token grants a one-click reconnect with no PIN
  5. rate limiting blocks brute force

The PIN is read from the sender's log, which stands in for the human reading it
off the menu bar.
"""
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time
from importlib import util as import_util

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "ws-acceptance.py")).read()
ns = {}
exec(src.split("passed = failed = 0")[0], ns)
ws_connect, ws_send, ws_read, parse_video = (
    ns["ws_connect"], ns["ws_send"], ns["ws_read"], ns["parse_video"])

HOST = os.environ.get("DS_HOST", "127.0.0.1")
PORT = int(os.environ.get("DS_WS_PORT", "8788"))
LOG = os.environ.get("DS_LOG", "/tmp/ds-app.log")
DEVICE = "test-device-0001"

passed = failed = 0


def check(label, ok, detail=""):
    global passed, failed
    if ok:
        print(f"  ✅ {label}" + (f" ({detail})" if detail else ""))
        passed += 1
    else:
        print(f"  ❌ {label}" + (f" ({detail})" if detail else ""))
        failed += 1


def latest_pin():
    """The PIN the sender is currently displaying."""
    try:
        text = open(LOG).read()
    except OSError:
        return None
    pins = re.findall(r"PIN (\d{4})", text)
    return pins[-1] if pins else None


class Session:
    def __init__(self):
        self.sock, self.buf = ws_connect(HOST, PORT)
        self.sock.settimeout(4)

    def send(self, obj):
        ws_send(self.sock, json.dumps(obj).encode())

    def hello(self, device_id=DEVICE, token=None, name="Test Receiver"):
        msg = {
            "type": "hello", "protocolVersion": 1, "client": "pairing-acceptance/1.0",
            "deviceId": device_id, "deviceName": name,
            "receiver": {"width": 1920, "height": 1080, "scale": 1.0, "refreshRate": 60},
        }
        if token:
            msg["token"] = token
        self.send(msg)

    def collect(self, seconds=3.0):
        """Gathers control messages and counts video frames."""
        control, frames = [], 0
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                op, data, self.buf = ws_read(self.sock, self.buf)
            except Exception:
                break
            if op == 0x1:
                control.append(json.loads(data))
            elif op == 0x2:
                frames += 1
        return control, frames

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def types(control):
    return [m.get("type") for m in control]


def find(control, kind):
    return next((m for m in control if m.get("type") == kind), None)


print("=== Task 4.1 — discovery and pairing acceptance ===\n")

# --- 0. discovery ------------------------------------------------------------
print("--- 0. Bonjour discovery ---")
proc = subprocess.Popen(["dns-sd", "-B", "_displayshare._tcp"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
time.sleep(4)
proc.terminate()
browse = proc.stdout.read()
check("sender is advertised over Bonjour", "_displayshare._tcp." in browse,
      "service visible to dns-sd")

# --- 1. unpaired receiver is refused ----------------------------------------
print("\n--- 1. unpaired receiver ---")
s1 = Session()
s1.hello()
control, frames = s1.collect(3)
err = find(control, "error")
check("refused with an explicit error", err is not None, f"code={err.get('code') if err else None}")
check("code is 'pairing_required'", err and err.get("code") == "pairing_required")
check("no video before pairing", frames == 0, f"{frames} frames")
check("no welcome before pairing", find(control, "welcome") is None)

pin = latest_pin()
check("sender generated a PIN", pin is not None, f"PIN {pin}")

# --- 2. wrong PIN ------------------------------------------------------------
print("\n--- 2. wrong PIN ---")
wrong = "0000" if pin != "0000" else "1111"
s1.send({"type": "pair", "pin": wrong, "deviceId": DEVICE, "deviceName": "Test Receiver"})
control, frames = s1.collect(2)
rejected = find(control, "error")
check("wrong PIN rejected", rejected and rejected.get("code") == "pair_rejected",
      rejected.get("message") if rejected else "")
check("still no video", frames == 0)

# --- 3. correct PIN ---------------------------------------------------------
print("\n--- 3. correct PIN ---")
s1.send({"type": "pair", "pin": pin, "deviceId": DEVICE, "deviceName": "Test Receiver"})
control, frames = s1.collect(4)
paired = find(control, "paired")
check("paired message received", paired is not None)
token = paired.get("token") if paired else None
check("token issued", bool(token), f"{len(token) if token else 0} hex chars")
check("session resumed to welcome", find(control, "welcome") is not None)
s1.close()

# --- 4. token grants one-click reconnect ------------------------------------
print("\n--- 4. reconnect with the stored token ---")
time.sleep(1)
s2 = Session()
s2.hello(token=token)
control, frames = s2.collect(3)
check("welcome without any PIN", find(control, "welcome") is not None)
check("no pairing_required on reconnect",
      not any(m.get("code") == "pairing_required" for m in control))
s2.close()

# --- 5. a stolen token on another device is refused -------------------------
print("\n--- 5. token bound to its device ---")
time.sleep(1)
s3 = Session()
s3.hello(device_id="different-device", token=token)
control, _ = s3.collect(3)
err = find(control, "error")
check("other device with same token is refused",
      err is not None and err.get("code") == "pairing_required",
      f"code={err.get('code') if err else None}")

# --- 6. rate limiting -------------------------------------------------------
print("\n--- 6. brute-force rate limiting ---")
pin2 = latest_pin()
attacker = "attacker-device"
rate_limited = False
for i in range(6):
    s3.send({"type": "pair", "pin": "9999" if pin2 != "9999" else "8888",
             "deviceId": attacker, "deviceName": "Attacker"})
    control, _ = s3.collect(1.2)
    err = find(control, "error")
    if err and "Too many attempts" in (err.get("message") or ""):
        rate_limited = True
        check("rate limited after repeated wrong PINs", True, f"blocked on attempt {i + 1}")
        break
check("brute force is blocked", rate_limited) if not rate_limited else None
s3.close()

print(f"\n=== {passed} passed, {failed} failed ===")
sys.exit(1 if failed else 0)
