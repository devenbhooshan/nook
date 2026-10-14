#!/bin/bash
# Builds a signed, notarized Nook-<version>.dmg in ./build, ready to publish.
#
# Needs, once per Mac:
#   1. A "Developer ID Application" certificate in your login keychain (developer.apple.com → Certificates).
#   2. Notarization credentials stored in your keychain under the profile name "nook-notary":
#        xcrun notarytool store-credentials nook-notary --apple-id you@example.com --team-id TEAMID
#      It asks for an app-specific password (appleid.apple.com → Sign-In and Security → App-Specific Passwords).
#
# Nothing here is specific to one maintainer: override with NOOK_SIGN_IDENTITY and NOOK_NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${NOOK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
profile="${NOOK_NOTARY_PROFILE:-nook-notary}"
if [[ -z "$identity" ]]; then
    echo "No \"Developer ID Application\" certificate found in your keychain. See the comment at the top of this script." >&2
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
echo "Releasing Nook $version, signed as: $identity"

./scripts/test.sh
./scripts/build-app.sh >/dev/null

app="build/Nook.app"
# Inside out: the embedded framework, then the helper, then the app. Hardened runtime and a secure timestamp are
# required for notarization.
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Frameworks/SQLCipher.framework"
codesign --force --options runtime --timestamp --identifier "$bundle_id" --sign "$identity" "$app/Contents/MacOS/nook-mcp"
codesign --force --options runtime --timestamp --entitlements Resources/Nook.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

dmg="build/Nook-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Nook" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg"

echo "Submitting to Apple for notarization (usually a few minutes)…"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler staple "$app"

spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
echo "Done: $dmg"
