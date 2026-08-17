#!/usr/bin/env bash
# Task 1.1 acceptance — vd_helper lifecycle.
#
# Verifies the four criteria, including the two that pull against each other:
#   1. launching the app creates the virtual display
#   2. quitting removes it
#   3. force-killing the app leaves NO orphaned display
#   4. a crash does NOT tear down the helper mid-session (windows survive)
#
# (3) and (4) are reconciled by the helper's grace period: an unexpected
# disconnect keeps the display alive briefly so a relaunching app can re-attach,
# then exits if nobody does.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$HERE/.." && pwd)"
APP="${APP_PATH:-$MAC_DIR/.build/Build/Products/Debug/DisplayShare.app}"
VDSPIKE="$MAC_DIR/spike/.build/debug/vdspike"
GRACE=8

pass=0
fail=0

# Our virtual displays are tagged with vendor 0x444d ("DM") in
# VirtualDisplayHost, which is how we tell them from real monitors.
vd_count() { "$VDSPIKE" list 2>/dev/null | grep -c "0x444d" || true; }
vd_id()    { "$VDSPIKE" list 2>/dev/null | awk '$2=="0x444d"{print $1; exit}'; }
helper_running() { pgrep -x vd_helper >/dev/null 2>&1 && echo yes || echo no; }

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✅ $label"
    pass=$((pass+1))
  else
    echo "  ❌ $label (expected '$expected', got '$actual')"
    fail=$((fail+1))
  fi
}

cleanup() {
  pkill -x DisplayShare >/dev/null 2>&1
  pkill -x vd_helper >/dev/null 2>&1
  sleep 1
}

wait_for_helper_exit() {
  for _ in $(seq 1 24); do
    [[ "$(helper_running)" == "no" ]] && return 0
    sleep 0.25
  done
  return 1
}

launch_app() {
  open -n "$APP" --args --autostart
  # Display creation is async: poll rather than sleeping a fixed amount.
  for _ in $(seq 1 40); do
    [[ "$(vd_count)" -ge 1 ]] && return 0
    sleep 0.25
  done
  return 1
}

echo "=== Task 1.1 — vd_helper lifecycle acceptance ==="
echo "app: $APP"
[[ -d "$APP" ]] || { echo "❌ app not built at $APP"; exit 1; }
[[ -x "$VDSPIKE" ]] || { echo "❌ vdspike not built (needed to enumerate displays)"; exit 1; }

cleanup
check "no virtual display before we start" "0" "$(vd_count)"

# --- 1. launching creates the display ---------------------------------------
echo
echo "--- 1. launch creates the display ---"
launch_app || echo "  ⚠️  launch_app timed out waiting for a display"
check "virtual display exists after launch" "1" "$(vd_count)"
check "helper process is running" "yes" "$(helper_running)"
FIRST_ID="$(vd_id)"
echo "     display id: $FIRST_ID"

# --- 2. clean quit removes it ------------------------------------------------
echo
echo "--- 2. clean quit removes the display ---"
osascript -e 'tell application "DisplayShare" to quit' >/dev/null 2>&1 || pkill -TERM -x DisplayShare
for _ in $(seq 1 20); do
  [[ "$(vd_count)" -eq 0 ]] && break
  sleep 0.25
done
check "display removed on clean quit" "0" "$(vd_count)"
# The helper stops listening immediately but spends a moment letting
# CoreGraphics retire the display before exiting, so poll rather than sample.
wait_for_helper_exit
check "helper exited on clean quit" "no" "$(helper_running)"

# --- 4. crash does not tear down the helper ----------------------------------
# Run before (3) because it reuses the same live session.
echo
echo "--- 4. SIGKILL does NOT immediately destroy the display ---"
launch_app || echo "  ⚠️  launch_app timed out waiting for a display"
CRASH_ID="$(vd_id)"
echo "     display id before crash: $CRASH_ID"
pkill -KILL -x DisplayShare
sleep 1
check "display still alive 1s after SIGKILL" "1" "$(vd_count)"
check "helper survived the app crash" "yes" "$(helper_running)"
check "same display, not recreated" "$CRASH_ID" "$(vd_id)"

echo
echo "--- 4b. relaunch re-attaches to the SAME display ---"
launch_app || echo "  ⚠️  launch_app timed out waiting for a display"
check "still exactly one virtual display" "1" "$(vd_count)"
check "re-attached to the original display id" "$CRASH_ID" "$(vd_id)"

# --- 3. no orphan after the grace period expires ------------------------------
echo
echo "--- 3. SIGKILL with no relaunch leaves no orphan (waiting ${GRACE}s grace) ---"
pkill -KILL -x DisplayShare
sleep $((GRACE + 4))
check "display removed after grace period" "0" "$(vd_count)"
check "helper exited after grace period" "no" "$(helper_running)"

cleanup
echo
echo "=== $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]] || exit 1
