#!/bin/bash
# Build a signed + notarized, distributable UsageMonitor.app.
#
# Prereqs (one-time):
#   1. A "Developer ID Application" certificate installed in your login keychain
#      (requires a paid Apple Developer Program membership).
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
    echo "  Create one in Keychain Access, then re-run."
    exit 1
fi

echo "→ Building + signing with: $IDENTITY"
SIGN_IDENTITY="$IDENTITY" ./build.sh

# The keychain profile disappears between runs. Prefer the App Store Connect
# API key in ~/.orbit/notary.env when it is present. That file stays local.
NOTARY_ENV="${NOTARY_ENV:-$HOME/.orbit/notary.env}"
if [ -f "$NOTARY_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$NOTARY_ENV"
    set +a
fi
if [ -n "${ORBIT_NOTARY_KEY:-}" ] && [ -n "${ORBIT_NOTARY_KEY_ID:-}" ] && [ -n "${ORBIT_NOTARY_ISSUER:-}" ]; then
    NOTARY_ARGS=(--key "$ORBIT_NOTARY_KEY" --key-id "$ORBIT_NOTARY_KEY_ID" --issuer "$ORBIT_NOTARY_ISSUER")
    echo "→ Notary auth: App Store Connect API key"
else
    NOTARY_ARGS=(--keychain-profile "$PROFILE")
    echo "→ Notary auth: keychain profile $PROFILE"
fi

echo "→ Zipping for notarization"
mkdir -p "$DIST"; rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

echo "→ Stapling ticket"
xcrun stapler staple "$APP"
rm -f "$ZIP"; /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Gatekeeper assessment:"
spctl -a -vvv --type exec "$APP" 2>&1 || true

DMG="$DIST/UsageMonitor.dmg"
STAGE="$(mktemp -d)"
echo "→ Disk image"
ditto "$APP" "$STAGE/UsageMonitor.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Usage Monitor" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# Friends download the disk image. Gatekeeper checks that file, so sign it,
# notarize it, and staple the ticket onto the image itself.
echo "→ Signing disk image"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "→ Notarizing disk image"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
echo "→ Stapling disk image"
xcrun stapler staple "$DMG"
echo "→ Disk image Gatekeeper assessment:"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 || true

echo "✓ Notarized build ready: $ZIP"
echo "✓ Disk image ready: $DMG"
