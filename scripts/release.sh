#!/usr/bin/env bash
#
# Build, strip, sign (Developer ID), notarize, and staple a distributable AIHelper.app,
# and keep its dSYM so crash reports can be symbolicated.
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
# Writes output.zip (default AIHelper.zip) and, next to it, output.dSYM.zip with the
# debug symbols that the shipped binary no longer carries.
#
# Config (env vars, with defaults):
#   SIGN_IDENTITY   signing identity            (default: "Developer ID Application")
#   NOTARY_PROFILE  notarytool keychain profile (default: "aihelper-notary")
set -euo pipefail

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-aihelper-notary}"
DERIVED="build/release"
APP="$DERIVED/Build/Products/Release/AIHelper.app"
DSYM="$APP.dSYM"
ZIP="${1:-AIHelper.zip}"
DSYM_ZIP="${ZIP%.zip}.dSYM.zip"

echo "==> Building Release configuration"
xcodebuild -project AIHelper.xcodeproj -scheme AIHelper -configuration Release \
  -derivedDataPath "$DERIVED" build CODE_SIGNING_ALLOWED=NO >/dev/null

# A plain `build` never strips (only archive/install do), so strip here, as Archive
# would. The dSYM the build made from the unstripped binary keeps the symbols for
# crash reports, so check that it exists before they are gone.
echo "==> Stripping symbols (the dSYM keeps them)"
if [ ! -d "$DSYM" ]; then
  echo "error: no dSYM at $DSYM (Release needs DEBUG_INFORMATION_FORMAT = dwarf-with-dsym)" >&2
  exit 1
fi
strip "$APP/Contents/MacOS/AIHelper"

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

echo "==> Saving the dSYM next to the zip"
rm -f "$DSYM_ZIP"
ditto -c -k --keepParent "$DSYM" "$DSYM_ZIP"

echo "==> Gatekeeper assessment:"
spctl -a -vvv -t install "$APP" || true

echo "==> Done. Notarized, stapled artifact: $ZIP"
echo "    Debug symbols: $DSYM_ZIP (keep it: crash reports from this build need it)"
echo "    Publish with:  gh release create vX.Y --repo <owner>/aihelper --notes '...' $ZIP"
