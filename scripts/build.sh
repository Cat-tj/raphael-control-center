#!/bin/bash
# Builds "Raphael Control Center.app" with swiftc (no Xcode project needed).
#   scripts/build.sh            → build/Raphael Control Center.app
#   scripts/build.sh --install  → also replace ~/Applications/Raphael Control Center.app and open it
#   CONFIG=debug scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
NAME="Raphael Control Center"
EXE="RaphaelControlCenter"
BUNDLE_ID="id.altora.raphael-control-center"
VERSION=$(cat VERSION 2>/dev/null || echo 0.1.0)
APP="$ROOT/build/$NAME.app"
CONFIG=${CONFIG:-release}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

OPT=(-O -whole-module-optimization)
[ "$CONFIG" = debug ] && OPT=(-Onone -g)
SDK=$(xcrun --show-sdk-path)
ARCH=$(uname -m)
# The embedded Linux collector is Python inside a Swift string: make sure it still compiles.
python3 - <<'PY' || { echo "✗ embedded collector script has a Python error"; exit 1; }
import re
s = open("Sources/ControlCenter/MonitorStore.swift", encoding="utf-8").read()
m = re.search(r'static let linuxScript = #"""\n(.*?)\n\s*"""#', s, re.S)
lines = m.group(1).split("\n"); ind = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
body = "\n".join(l[ind:] for l in lines).split("<<'RAPHAEL_PY'\n", 1)[1].rsplit("RAPHAEL_PY", 1)[0]
compile(body, "collector", "exec")
PY
echo "▸ compiling ($CONFIG, $ARCH)"
swiftc -swift-version 5 "${OPT[@]}" -sdk "$SDK" -target "$ARCH-apple-macos14.0" \
  -module-name RaphaelControlCenter \
  Sources/App/*.swift Sources/ControlCenter/*.swift Sources/Workspace/*.swift Sources/WorkspaceUI/*.swift \
  -o "$APP/Contents/MacOS/$EXE" 2>&1 | grep -E ": error:" || true
[ -x "$APP/Contents/MacOS/$EXE" ] || { echo "✗ build failed"; exit 1; }

cp Resources/AppIcon.icns Resources/MenuBarIcon*.png Resources/AltoraLogo.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>raphael</string></array>
  </dict></array>
  <!-- Health checks hit plain http:// on LAN/Tailscale addresses. -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key><string>Raphael memantau server dan aplikasi di jaringan lokal dan Tailscale.</string>
  <key>NSAppleEventsUsageDescription</key><string>Raphael membuka Terminal untuk SSH ke server.</string>
</dict></plist>
PLIST

# A stable signing identity keeps Keychain access across builds (create once in Keychain
# Access → Certificate Assistant → Create a Certificate…, name "Raphael Local", type Code Signing).
IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q '"Raphael Local"'; then IDENTITY="Raphael Local"; fi
codesign --force --deep --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing" || true
echo "✓ $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/$NAME.app"
  mkdir -p "$HOME/Applications"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1; pkill -x "$EXE" 2>/dev/null || true; sleep 0.5
  rm -rf "$DEST"; cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  open "$DEST"
  echo "✓ installed and launched $DEST"
fi
