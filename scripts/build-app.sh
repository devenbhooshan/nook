#!/bin/bash
# Builds Nook.app into ./build. Pass --debug for a debug build.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="release"
[[ "${1:-}" == "--debug" ]] && configuration="debug"

# NOOK_DEV=1 builds a dev copy that times every action (Mail → Copy Diagnostics). Releases never set it.
dev=()
[[ "${NOOK_DEV:-}" == "1" ]] && dev=(-Xswiftc -DNOOK_DEV)
# Extra compiler flags. CI passes the test run's (-enable-testing) so this reuses its release build instead of
# compiling everything a third time. Never set for builds people run.
read -r -a extra <<< "${NOOK_SWIFT_FLAGS:-}"
dev+=(${extra[@]+"${extra[@]}"})
swift build -c "$configuration" ${dev[@]+"${dev[@]}"}
bin="$(swift build -c "$configuration" ${dev[@]+"${dev[@]}"} --show-bin-path)"

# One build at a time: two at once would delete and copy over each other's half-signed app.
mkdir -p build
lock="build/.build-app.lock"
until mkdir "$lock" 2>/dev/null; do
    # A lock left by a build that died (its process is gone) doesn't count.
    if [[ -f "$lock/pid" ]] && ! kill -0 "$(cat "$lock/pid")" 2>/dev/null; then rm -rf "$lock"; continue; fi
    echo "waiting for another build-app.sh to finish..." >&2
    sleep 1
done
echo $$ > "$lock/pid"

# Built and signed beside the real one, then swapped in whole. Nothing (a running Nook, Claude Code starting
# nook-mcp) ever sees a half-copied or unsigned app, which Keychain would treat as a stranger and ask about.
final="build/Nook.app"
staging="build/.Nook.app.building"
app="$staging"
trap 'rm -rf "$staging" "$lock"' EXIT
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Nook" "$app/Contents/MacOS/Nook"
cp "$bin/nook-mcp" "$app/Contents/MacOS/nook-mcp"

# SQLCipher (the mail store's encryption) is a framework: embed it and point both executables at it.
mkdir -p "$app/Contents/Frameworks"
cp -R "$bin/SQLCipher.framework" "$app/Contents/Frameworks/"
for executable in Nook nook-mcp; do
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/$executable" 2>/dev/null || true
done
cp Resources/Info.plist "$app/Contents/Info.plist"

# Generate the icon once; it's cached in build/.
if [[ ! -f build/AppIcon.icns ]]; then
    iconset="build/AppIcon.iconset"
    rm -rf "$iconset" && mkdir -p "$iconset"
    swift scripts/make-icon.swift build/AppIcon-1024.png >/dev/null
    for size in 16 32 128 256 512; do
        sips -z $size $size build/AppIcon-1024.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) build/AppIcon-1024.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Sign with the most stable identity available, so every build keeps the same identity and Keychain doesn't
# ask again after each rebuild:
#   1. $NOOK_SIGN_IDENTITY, if set
#   2. a "Developer ID Application" certificate in your keychain
#   3. the local certificate from scripts/setup-signing.sh
#   4. ad hoc
# Release builds (timestamped and notarized) come from scripts/release.sh.
identity="${NOOK_SIGN_IDENTITY:-}"
signing=()
label=""
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi
if [[ -n "$identity" ]]; then
    label="$identity"
    signing=(--options runtime)
else
    signing_keychain="$HOME/Library/Application Support/Nook/Signing/signing.keychain-db"
    signing_password="$(security find-generic-password -s "Nook Local Signing Keychain" -a "$USER" -w 2>/dev/null || true)"
    if [[ -f "$signing_keychain" && -z "$signing_password" ]]; then
        echo "warning: the local signing keychain predates random passwords; re-run scripts/setup-signing.sh" >&2
    fi
    if [[ -f "$signing_keychain" && -n "$signing_password" ]]; then
        security unlock-keychain -p "$signing_password" "$signing_keychain"
        identity="$(security find-identity -v -p codesigning "$signing_keychain" | awk '/Nook Local Signing/ { print $2; exit }')"
        if [[ -n "$identity" ]]; then
            signing=(--keychain "$signing_keychain")
            label="Nook Local Signing"
        fi
    fi
fi
[[ -z "$identity" ]] && identity="-"

# nook-mcp shares the app's identifier, so with a stable signature the Keychain treats it as Nook and lets it
# read the mail store's encryption key without asking.
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
# Inside out: the embedded framework first, then the helper, then the app. With the hardened runtime, macOS only
# loads libraries signed by the same team, so the framework is re-signed with our identity.
codesign --force ${signing[@]+"${signing[@]}"} --sign "$identity" "$app/Contents/Frameworks/SQLCipher.framework" >/dev/null
codesign --force ${signing[@]+"${signing[@]}"} --identifier "$bundle_id" --sign "$identity" "$app/Contents/MacOS/nook-mcp" >/dev/null
codesign --force ${signing[@]+"${signing[@]}"} --entitlements Resources/Nook.entitlements --sign "$identity" "$app" >/dev/null

# Keychain trusts the signature's designated requirement. With a certificate, that's the identifier and team,
# the same on every build. A requirement that's just a hash means the signing didn't take, and every rebuild
# would ask for the password again: stop rather than install that.
if [[ "$identity" != "-" ]]; then
    for code in "$app" "$app/Contents/MacOS/nook-mcp"; do
        requirement="$(codesign -d -r- "$code" 2>&1 | grep designated || true)"
        if [[ "$requirement" != *"identifier \"$bundle_id\""* || "$requirement" == *cdhash* ]]; then
            echo "error: $code isn't signed with a stable identity ($requirement)" >&2
            exit 1
        fi
    done
fi
codesign --verify --strict --deep "$app"

rm -rf "$final.old"
[[ -d "$final" ]] && mv "$final" "$final.old"
mv "$app" "$final"
rm -rf "$final.old"
app="$final"

if [[ "$identity" == "-" ]]; then
    echo "Built $app (ad hoc: macOS may ask for Keychain access after each rebuild; run scripts/setup-signing.sh once to stop that)"
else
    echo "Built $app (signed with $label)"
fi
