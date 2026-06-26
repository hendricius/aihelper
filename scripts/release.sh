#!/usr/bin/env bash
#
# Build, sign (Developer ID), notarize, and staple a distributable AIHelper.app.
#
# Prerequisites (one-time):
#   - A "Developer ID Application" certificate in your keychain
#     (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   - A notarytool keychain profile, created once with:
#       xcrun notarytool store-credentials "aihelper-notary" \
#         --apple-id "you@example.com" --team-id "YOURTEAMID"
#     (it will prompt for an app-specific password from appleid.apple.com).
#
# Usage:
#   bash scripts/release.sh [output.zip]
#
# Config (env vars, with defaults):
#   SIGN_IDENTITY   signing identity            (default: "Developer ID Application")
#   NOTARY_PROFILE  notarytool keychain profile (default: "aihelper-notary")
set -euo pipefail

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-aihelper-notary}"
DERIVED="build/release"
APP="$DERIVED/Build/Products/Release/AIHelper.app"
ZIP="${1:-AIHelper.zip}"

echo "==> Building Release configuration"
xcodebuild -project AIHelper.xcodeproj -scheme AIHelper -configuration Release \
  -derivedDataPath "$DERIVED" build CODE_SIGNING_ALLOWED=NO >/dev/null

echo "==> Signing with Developer ID + hardened runtime"
codesign --force --options runtime --timestamp \
  --entitlements AIHelper/AIHelper.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Submitting for notarization (profile: $NOTARY_PROFILE)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper assessment:"
spctl -a -vvv -t install "$APP" || true

echo "==> Done. Notarized, stapled artifact: $ZIP"
echo "    Publish with:  gh release create vX.Y --repo <owner>/aihelper --notes '...' $ZIP"
