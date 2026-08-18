#!/usr/bin/env bash
# Display Share — build and install the Mac sender from source.
#
# Building from source is the easiest path for this project, not the hardest:
# a locally built app carries no quarantine attribute, so macOS launches it
# without the "Apple cannot check it" warning that the downloaded .dmg triggers.
#
#   ./install.sh                 build + install to /Applications
#   ./install.sh --prefix DIR    install somewhere else
#   ./install.sh --no-open       don't open System Settings at the end
#   ./install.sh --uninstall     remove the app and its stored data
set -euo pipefail

PREFIX="/Applications"
OPEN_SETTINGS=1
UNINSTALL=0
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --no-open) OPEN_SETTINGS=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

APP="$PREFIX/DisplayShare.app"

if [[ "$UNINSTALL" == 1 ]]; then
  bold "Uninstalling Display Share"
  pkill -x DisplayShare 2>/dev/null || true
  pkill -x vd_helper 2>/dev/null || true
  [[ -d "$APP" ]] && rm -rf "$APP" && ok "removed $APP"
  rm -rf "$HOME/Library/Application Support/DisplayShare" && ok "removed stored pairings"
  defaults delete in.theboringpeople.displayshare 2>/dev/null && ok "removed preferences" || true
  echo
  echo "macOS keeps its permission entries. To clear them fully, remove"
  echo "Display Share from System Settings → Privacy & Security → Screen Recording"
  echo "and → Accessibility."
  exit 0
fi

# --- 1. requirements --------------------------------------------------------
bold "1/5  Checking requirements"

[[ "$(uname -s)" == "Darwin" ]] || die "the sender only runs on macOS (the receiver is the Windows app)."

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MACOS_MAJOR < 14 )); then
  die "macOS 14 or later required; this is $(sw_vers -productVersion)."
fi
ok "macOS $(sw_vers -productVersion)"

if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode command line tools missing — launching the installer"
  xcode-select --install || true
  die "re-run this script once the command line tools finish installing."
fi
ok "Xcode tools at $(xcode-select -p)"

if ! command -v xcodebuild >/dev/null 2>&1; then
  die "xcodebuild not found. Install Xcode from the App Store, then run:
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    warn "xcodegen missing — installing with Homebrew"
    brew install xcodegen
  else
    die "xcodegen is required. Install Homebrew from https://brew.sh then:
    brew install xcodegen"
  fi
fi
ok "xcodegen $(xcodegen --version 2>&1 | tr -d '\n')"

# --- 2. generate + build ----------------------------------------------------
bold "2/5  Building (this takes a minute or two)"
cd "$REPO_DIR/mac"
xcodegen generate --spec project.yml >/dev/null
ok "Xcode project generated"

BUILD_LOG="$(mktemp)"
if ! xcodebuild -project DisplayShare.xcodeproj -scheme DisplayShare \
      -configuration Release -derivedDataPath ./.build \
      CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      ONLY_ACTIVE_ARCH=YES \
      build > "$BUILD_LOG" 2>&1; then
  echo
  grep -E "error:" "$BUILD_LOG" | head -20
  die "build failed. Full log: $BUILD_LOG"
fi
BUILT="$REPO_DIR/mac/.build/Build/Products/Release/DisplayShare.app"
[[ -d "$BUILT" ]] || die "build reported success but $BUILT is missing."

# Re-sign with an EXPLICIT identifier.
#
# macOS keys TCC permissions on the code-signing identifier. Left to itself an
# ad-hoc Release build signs as "DisplayShare" (the executable name) rather than
# the bundle id, so it looks like a DIFFERENT app to macOS than any copy the
# user already granted — permission appears granted in System Settings while the
# app still reports it missing. Sign nested code first, then the bundle.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT/Contents/Info.plist")"
codesign --force --sign - --identifier "$BUNDLE_ID.core" \
  "$BUILT/Contents/Frameworks/DisplayShareCore.framework" 2>/dev/null || true
codesign --force --sign - --identifier "$BUNDLE_ID.vd-helper" \
  "$BUILT/Contents/MacOS/vd_helper" 2>/dev/null || true
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --entitlements "$REPO_DIR/mac/DisplayShare/DisplayShare.entitlements" "$BUILT"
SIGNED_ID="$(codesign -dvv "$BUILT" 2>&1 | awk -F= '/^Identifier=/{print $2}')"
[[ "$SIGNED_ID" == "$BUNDLE_ID" ]] || die "signing identifier is '$SIGNED_ID', expected '$BUNDLE_ID'"
ok "signed as $SIGNED_ID (this is the identity macOS ties permissions to)"
# Native arch only, deliberately: this is your machine, so a universal binary
# would double the build time for nothing. The released .dmg is universal.
ok "built $(du -sh "$BUILT" | cut -f1) app bundle for $(uname -m)"

# --- 3. install -------------------------------------------------------------
bold "3/5  Installing to $PREFIX"
pkill -x DisplayShare 2>/dev/null || true
pkill -x vd_helper 2>/dev/null || true
mkdir -p "$PREFIX"
rm -rf "$APP"
cp -R "$BUILT" "$APP"
# A locally built app is not quarantined, but strip the attribute anyway in
# case the repo itself arrived as a downloaded zip.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
ok "installed $APP"

# --- 4. permissions ---------------------------------------------------------
bold "4/5  Permissions"
echo "  Display Share needs Screen Recording to capture the display it creates."
echo "  It never captures your real screen — but macOS does not distinguish, so"
echo "  the usual recording indicator appears."
echo
echo "  Remote control (optional) additionally needs Accessibility."
echo
warn "macOS will not let a script grant these. You must click them yourself."
echo "  A freshly built copy is a NEW identity to macOS, so if you have granted"
echo "  these before for a different copy, you must grant them again for this one."

if [[ "$OPEN_SETTINGS" == 1 ]]; then
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true
  ok "opened Privacy & Security → Screen Recording"
fi

# --- 5. done ----------------------------------------------------------------
bold "5/5  Done"
cat <<EOF

  Next:
    1. Launch Display Share (it lives in the menu bar, no Dock icon).
    2. Grant Screen Recording when asked, then click Start.
    3. On the receiver, open the Windows app — or for a quick test, open
       http://localhost:8787 in a browser on this Mac.
    4. Enter the 4-digit PIN shown in the menu bar.

  Ports: 8787 (viewer page), 8788 (video + control).
  Uninstall: ./install.sh --uninstall

EOF
open -a "$APP" 2>/dev/null && ok "launched Display Share" || true
