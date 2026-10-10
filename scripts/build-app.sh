#!/bin/bash
# Builds Nook.app into ./build. Pass --debug for a debug build.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="release"
[[ "${1:-}" == "--debug" ]] && configuration="debug"

swift build -c "$configuration"
bin="$(swift build -c "$configuration" --show-bin-path)"

app="build/Nook.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Nook" "$app/Contents/MacOS/Nook"
cp "$bin/nook-mcp" "$app/Contents/MacOS/nook-mcp"
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
    if [[ -f "$signing_keychain" ]]; then
        security unlock-keychain -p "nook-local-signing" "$signing_keychain"
        identity="$(security find-identity -v -p codesigning "$signing_keychain" | awk '/Nook Local Signing/ { print $2; exit }')"
        if [[ -n "$identity" ]]; then
            signing=(--keychain "$signing_keychain")
            label="Nook Local Signing"
        fi
    fi
fi
[[ -z "$identity" ]] && identity="-"

codesign --force ${signing[@]+"${signing[@]}"} --sign "$identity" "$app/Contents/MacOS/nook-mcp" >/dev/null
codesign --force ${signing[@]+"${signing[@]}"} --sign "$identity" "$app" >/dev/null

if [[ "$identity" == "-" ]]; then
    echo "Built $app (ad hoc: macOS may ask for Keychain access after each rebuild; run scripts/setup-signing.sh once to stop that)"
else
    echo "Built $app (signed with $label)"
fi
