#!/bin/bash
# Builds build/DiscordActivity.app. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DiscordActivity.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/DiscordActivity" main.swift

# App icon: AppIcon.png (1024 px, already shaped, transparent outside) becomes Resources/AppIcon.icns.
if [ -f AppIcon.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET" "$APP/Contents/Resources"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

# A real signing identity keeps the Accessibility permission across rebuilds;
# ad-hoc signing ("-") works too, but macOS asks for the permission again after each build.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -z "$IDENTITY" ] || ! codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    codesign --force --sign - "$APP"
    echo "Firmada ad-hoc"
else
    echo "Firmada con: $IDENTITY"
fi
echo "Lista: $APP"
