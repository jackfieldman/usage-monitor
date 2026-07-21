#!/bin/bash
# Build UsageMonitor.app from UsageMonitor.swift.
#
# Signing: uses a "Developer ID Application" certificate if one is installed
# (or set SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"),
# otherwise falls back to an ad-hoc signature. Ad-hoc is enough to build and
# run locally and for "Open at Login" to stick; a real Developer ID is only
# needed to hand a build to someone else without a Gatekeeper prompt.
set -euo pipefail
cd "$(dirname "$0")"

APP="UsageMonitor.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
mkdir -p "$MACOS" "$RES"

swiftc -O UsageMonitor.swift -o "$MACOS/UsageMonitor" -framework AppKit

# App icon — used by Finder, the Dock, and macOS notifications.
cp AppIcon.icns "$RES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>UsageMonitor</string>
    <key>CFBundleDisplayName</key>     <string>Usage Monitor</string>
    <key>CFBundleIdentifier</key>      <string>com.usagemonitor.app</string>
    <key>CFBundleExecutable</key>      <string>UsageMonitor</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleVersion</key>         <string>2.3.1</string>
    <key>CFBundleShortVersionString</key> <string>2.3.1</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSUIElement</key>             <true/>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
</dict>
</plist>
PLIST

# --- sign -------------------------------------------------------------------
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 'Developer ID Application' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
fi

if [ -n "$IDENTITY" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "Built $APP (signed: $IDENTITY)"
else
    codesign --force --deep --sign - "$APP"
    echo "Built $APP (ad-hoc signed — fine for local use)"
fi
