#!/bin/bash
# Build a signed + notarized, distributable UsageMonitor.app.
#
# Prereqs (one-time — see SIGNING.md):
#   1. A "Developer ID Application" certificate installed in your login keychain.
#   2. A stored notarytool credential profile:
#        xcrun notarytool store-credentials usage-monitor \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# Output: dist/UsageMonitor.zip  (stapled, ready to hand to anyone).
set -euo pipefail
cd "$(dirname "$0")"

APP="UsageMonitor.app"
DIST="dist"
ZIP="$DIST/UsageMonitor.zip"
PROFILE="${NOTARY_PROFILE:-usage-monitor}"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' | sed -E 's/.*"([^"]+)".*/\1/' || true)}"
if [ -z "$IDENTITY" ]; then
    echo "✗ No 'Developer ID Application' certificate found."
    echo "  Follow SIGNING.md to create one, then re-run."
    exit 1
fi

echo "→ Building + signing with: $IDENTITY"
SIGN_IDENTITY="$IDENTITY" ./build.sh

echo "→ Zipping for notarization"
mkdir -p "$DIST"; rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "→ Stapling ticket"
xcrun stapler staple "$APP"
rm -f "$ZIP"; /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Gatekeeper assessment:"
spctl -a -vvv --type exec "$APP" 2>&1 || true

echo "✓ Notarized build ready: $ZIP"
