#!/usr/bin/env bash
# Task 6.1 — build, sign, notarize and package the Mac app.
#
#   codesign  ->  notarytool submit --wait  ->  stapler staple  ->  .dmg
#
# Runs unsigned by default so the build and DMG can be exercised without a
# certificate. Signing and notarization switch on only when credentials are
# present, and the script says clearly which stage it skipped and why — a DMG
# that was never notarized must never look like one that was.
#
# Credentials come from the environment, never the repo:
#   DS_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   DS_TEAM_ID         Apple Developer Team ID
#   DS_APPLE_ID        Apple ID for notarytool
#   DS_APP_PASSWORD    app-specific password (NOT the Apple ID password)
# or, preferred in CI:
#   DS_NOTARY_PROFILE  a keychain profile made by `notarytool store-credentials`
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$HERE/.." && pwd)"
# Not a dotted directory: actions/upload-artifact v4 skips hidden paths by
# default, so a .release/ output silently uploaded nothing.
BUILD_DIR="${DS_BUILD_DIR:-$MAC_DIR/dist}"
APP_NAME="DisplayShare"
DMG_NAME="${DS_DMG_NAME:-DisplayShare}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MAC_DIR/DisplayShare/Info.plist" 2>/dev/null || echo 0.1.0)"
# Info.plist uses $(MARKETING_VERSION); read the real value from project.yml.
if [[ "$VERSION" == *'$'* ]]; then
  # Take everything after the colon and strip quotes/space. The previous
  # pattern assumed the value was QUOTED; release-please rewrites it unquoted,
  # which produced a DMG literally named DisplayShare-.MARKETING_VERSION.0.2.0.
  VERSION="$(awk -F: '/MARKETING_VERSION/{gsub(/[" ]/,"",$2); print $2; exit}' "$MAC_DIR/project.yml")"
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m    ✓ %s\033[0m\n' "$1"; }

SIGNED=0
NOTARIZED=0

# ---------------------------------------------------------------- build
step "Generating Xcode project"
command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)"; exit 1; }
(cd "$MAC_DIR" && xcodegen generate --spec project.yml >/dev/null)
ok "project generated"

step "Building universal Release ($VERSION)"
if [[ -n "${DS_SIGN_IDENTITY:-}" ]]; then
  SIGN_ARGS=(
    "DS_CODE_SIGN_IDENTITY=$DS_SIGN_IDENTITY"
    "DS_CODE_SIGNING_REQUIRED=YES"
    "DS_CODE_SIGNING_ALLOWED=YES"
  )
  [[ -n "${DS_TEAM_ID:-}" ]] && SIGN_ARGS+=("DEVELOPMENT_TEAM=$DS_TEAM_ID")
else
  # Ad-hoc: exercises the whole pipeline shape without a certificate.
  SIGN_ARGS=(
    "DS_CODE_SIGN_IDENTITY=-"
    "DS_CODE_SIGNING_REQUIRED=NO"
    "DS_CODE_SIGNING_ALLOWED=YES"
  )
  warn "DS_SIGN_IDENTITY not set — building ad-hoc signed"
fi

rm -rf "$BUILD_DIR"
# ARCHS and ONLY_ACTIVE_ARCH must be forced on the COMMAND LINE, and the
# destination must be generic: with a concrete "My Mac" destination xcodebuild
# narrows to the host architecture and quietly produces a single-arch binary
# even when the project asks for both.
(cd "$MAC_DIR" && xcodebuild \
  -project DisplayShare.xcodeproj \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  "${SIGN_ARGS[@]}" \
  build >"$BUILD_DIR-build.log" 2>&1) || {
    echo "build failed; tail of log:"; tail -30 "$BUILD_DIR-build.log"; exit 1; }

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "app not found at $APP"; exit 1; }
ok "built $APP"

step "Verifying universal binaries"
for binary in "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/MacOS/vd_helper"; do
  archs="$(lipo -archs "$binary" 2>/dev/null || echo "?")"
  echo "    $(basename "$binary"): $archs"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] \
    || { echo "NOT universal: $binary ($archs)"; exit 1; }
done
ok "arm64 + x86_64 present in app and helper"

# ------------------------------------------------------------- app icon
# actool writes an AppIcon.icns containing only FOUR representations — 16, 32,
# 128 and 256 — out of an asset catalogue that carries all ten. Wherever macOS
# wants a size that is not in the file it falls back to a generic icon, which is
# Get Info, Launchpad, and Finder at anything above a small icon size. Every
# release so far has shipped looking like it had no icon.
#
# iconutil builds the full set from the same PNGs. This must run BEFORE signing:
# changing a resource afterwards invalidates the signature.
step "Building a complete app icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp "$MAC_DIR/DisplayShare/Assets.xcassets/AppIcon.appiconset"/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Read the file back rather than trusting the tool. The shipped icon was
# missing its large sizes for every release up to 0.14.1 and nothing noticed,
# because an .icns with four entries is a perfectly valid .icns.
python3 - "$APP/Contents/Resources/AppIcon.icns" <<'PYEOF'
import struct, sys

REQUIRED = {
    b"ic07": "128", b"ic13": "256 (128@2x)", b"ic08": "256",
    b"ic14": "512 (256@2x)", b"ic09": "512", b"ic10": "1024 (512@2x)",
}

data = open(sys.argv[1], "rb").read()
if data[:4] != b"icns":
    sys.exit("not an icns file")

present, offset = set(), 8
while offset + 8 <= len(data):
    kind = data[offset:offset + 4]
    length = struct.unpack(">I", data[offset + 4:offset + 8])[0]
    if length < 8:
        break
    present.add(kind)
    offset += length

missing = [f"{k.decode()} ({v})" for k, v in REQUIRED.items() if k not in present]
if missing:
    sys.exit("app icon is missing representations: " + ", ".join(missing))
print(f"    {len(present)} representations, {len(data):,} bytes")
PYEOF
ok "app icon carries every size macOS asks for"

# ---------------------------------------------------------------- sign
# Signing order matters: nested code FIRST, outermost LAST, or the outer
# signature is invalidated by later changes inside the bundle.
if [[ -n "${DS_SIGN_IDENTITY:-}" ]]; then
  step "Signing with Developer ID (hardened runtime)"
  ENTITLEMENTS="$MAC_DIR/DisplayShare/DisplayShare.entitlements"

  # vd_helper is a sibling executable, not a framework; it needs its own
  # signature and its own entitlements.
  codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DS_SIGN_IDENTITY" \
    "$APP/Contents/MacOS/vd_helper"
  ok "signed vd_helper"

  for framework in "$APP/Contents/Frameworks/"*.framework; do
    [[ -e "$framework" ]] || continue
    codesign --force --timestamp --options runtime \
      --sign "$DS_SIGN_IDENTITY" "$framework"
    ok "signed $(basename "$framework")"
  done

  codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DS_SIGN_IDENTITY" "$APP"
  ok "signed $APP_NAME.app"

  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
  SIGNED=1
else
  warn "skipping Developer ID signing (no DS_SIGN_IDENTITY)"
fi

# ------------------------------------------------------------- notarize
if [[ "$SIGNED" == 1 ]]; then
  step "Notarizing"
  ZIP="$BUILD_DIR/$APP_NAME-notarize.zip"
  # ditto preserves symlinks and extended attributes; `zip` does not.
  ditto -c -k --keepParent "$APP" "$ZIP"

  if [[ -n "${DS_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$DS_NOTARY_PROFILE" --wait
  elif [[ -n "${DS_APPLE_ID:-}" && -n "${DS_APP_PASSWORD:-}" && -n "${DS_TEAM_ID:-}" ]]; then
    xcrun notarytool submit "$ZIP" \
      --apple-id "$DS_APPLE_ID" \
      --password "$DS_APP_PASSWORD" \
      --team-id "$DS_TEAM_ID" \
      --wait
  else
    warn "no notarytool credentials; skipping notarization"
    SKIP_NOTARY=1
  fi

  if [[ -z "${SKIP_NOTARY:-}" ]]; then
    # Stapling attaches the ticket so Gatekeeper works offline.
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    NOTARIZED=1
    ok "notarized and stapled"
  fi
else
  warn "skipping notarization (app is not Developer ID signed)"
fi

# ------------------------------------------------------------------ dmg
step "Building DMG"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# NO Applications symlink here. create-dmg's --app-drop-link makes its own, and
# a pre-existing one makes it die with "ln: .../Applications: File exists" — which
# this script hid behind >/dev/null || true, so every release since this file was
# written silently shipped the unstyled hdiutil fallback instead. The fallback
# below adds the symlink for the case where create-dmg really is unavailable.

DMG="$BUILD_DIR/$DMG_NAME-$VERSION.dmg"
rm -f "$DMG"

# Task 9.3: the window explains the install and warns about the unsigned first
# launch BEFORE the user meets that dialog. The text is drawn into the
# background rather than shipped as a read-me beside the app, because a second
# icon competes with the drag gesture and mostly goes unread.
BACKGROUND="$BUILD_DIR/dmg-background.png"
BACKGROUND_ARGS=()
if swift "$HERE/make-dmg-background.swift" "$BACKGROUND" "$VERSION" 2>/dev/null; then
  BACKGROUND_ARGS=(--background "$BACKGROUND")
else
  warn "could not render the DMG background; the window will be plain"
fi

if command -v create-dmg >/dev/null; then
  # Styled window, sized and positioned so the drag gesture is self-evident.
  # The icon row sits at y=180 to line up with the arrow in the background.
  create-dmg \
    --volname "$APP_NAME $VERSION" \
    --window-pos 200 120 --window-size 640 400 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 160 180 \
    --app-drop-link 480 180 \
    --no-internet-enable \
    "${BACKGROUND_ARGS[@]}" \
    "$DMG" "$STAGE" >"$BUILD_DIR/create-dmg.log" 2>&1 || true
  # Report the reason rather than discarding it. Silently degrading to an
  # unstyled image is how the broken --app-drop-link above went unnoticed.
  if [[ ! -f "$DMG" ]]; then
    warn "create-dmg failed: $(tail -1 "$BUILD_DIR/create-dmg.log" 2>/dev/null)"
  fi
fi

if [[ ! -f "$DMG" ]]; then
  warn "falling back to hdiutil (valid, but unstyled and without the notice)"
  ln -s /Applications "$STAGE/Applications" 2>/dev/null || true
  hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
fi
ok "created $DMG"

if [[ "$SIGNED" == 1 ]]; then
  codesign --force --sign "$DS_SIGN_IDENTITY" "$DMG"
  # The DMG itself is notarized too, so Gatekeeper accepts the download.
  if [[ -z "${SKIP_NOTARY:-}" ]]; then
    if [[ -n "${DS_NOTARY_PROFILE:-}" ]]; then
      xcrun notarytool submit "$DMG" --keychain-profile "$DS_NOTARY_PROFILE" --wait
    else
      xcrun notarytool submit "$DMG" --apple-id "$DS_APPLE_ID" \
        --password "$DS_APP_PASSWORD" --team-id "$DS_TEAM_ID" --wait
    fi
    xcrun stapler staple "$DMG"
    ok "DMG signed, notarized and stapled"
  fi
fi

# --------------------------------------------------------------- report
step "Gatekeeper assessment"
spctl -a -vvv -t install "$DMG" 2>&1 | sed 's/^/    /' || true

step "Result"
echo "    dmg:        $DMG"
echo "    universal:  yes (arm64 + x86_64)"
echo "    signed:     $([[ "$SIGNED" == 1 ]] && echo 'Developer ID' || echo 'NO — ad-hoc only')"
echo "    notarized:  $([[ "$NOTARIZED" == 1 ]] && echo yes || echo 'NO')"
if [[ "$NOTARIZED" != 1 ]]; then
  echo
  warn "This DMG will show a Gatekeeper warning on another Mac."
  warn "Set DS_SIGN_IDENTITY and notarytool credentials to produce a shippable build."
fi
