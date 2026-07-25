#!/bin/bash
#
# Builds Clickwheel.app.
#
# SwiftPM produces a bare executable, so the bundle is assembled here: compile
# the Metal materials, build the binary, lay out the .app, and sign it.
#
#   ./Scripts/build_app.sh            debug build
#   ./Scripts/build_app.sh release    optimised build
#
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Clickwheel.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

if [ ! -f "$ROOT/Sources/MusicBridge/include/Music.h" ]; then
    echo "==> Generating Music.app bridge header"
    "$ROOT/Scripts/regenerate_bridge.sh"
fi

echo "==> Compiling Metal materials"
# SwiftUI's ShaderLibrary.default expects an Xcode-built default.metallib, which
# SwiftPM never produces — so the shaders are compiled into a named library and
# loaded by URL at runtime instead.
xcrun metal -O \
    -o Sources/Clickwheel/Resources/Clickwheel.metallib \
    Sources/Clickwheel/Shaders/ipod.metal

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --disable-sandbox

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_DIR/Clickwheel" "$MACOS/Clickwheel"

# SwiftPM puts target resources in a side bundle; it has to travel with the app.
if [ -d "$BIN_DIR/Clickwheel_Clickwheel.bundle" ]; then
    cp -R "$BIN_DIR/Clickwheel_Clickwheel.bundle" "$RESOURCES/"
fi

echo "==> Building icon"
# Regenerated from the source artwork each build so the icon can't drift out of
# sync with it. `make_icon.swift` trims the frame and lays it out on Apple's
# icon grid; this turns that master into the .icns Finder and the Dock want.
if [ -f "$ROOT/Resources/icon-1024.png" ]; then
    ICONSET="$ROOT/build/Clickwheel.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ROOT/Resources/icon-1024.png" \
            --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
        sips -z $((size * 2)) $((size * 2)) "$ROOT/Resources/icon-1024.png" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$RESOURCES/Clickwheel.icns"
    rm -rf "$ICONSET"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Clickwheel</string>
    <key>CFBundleDisplayName</key>
    <string>Clickwheel</string>
    <key>CFBundleIdentifier</key>
    <string>com.alexissantos.clickwheel</string>
    <key>CFBundleExecutable</key>
    <string>Clickwheel</string>
    <key>CFBundleIconFile</key>
    <string>Clickwheel</string>
    <key>CFBundleIconName</key>
    <string>Clickwheel</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>es</string>
    </array>
    <!-- Required: without this string, macOS denies the Apple events used to
         drive Music.app and the app silently sees an empty library. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Clickwheel controls Apple Music to play your starred songs.</string>
</dict>
PLIST
echo "</plist>" >> "$CONTENTS/Info.plist"

echo "==> Signing"
# A stable signing identity matters here: macOS ties the Automation permission
# to the signature, so an ad-hoc signature that changes each build would make
# the user re-approve access every time.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')"

if [ -n "$IDENTITY" ]; then
    echo "    using: $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "    no Developer identity found, signing ad-hoc"
    codesign --force --sign - "$APP"
fi

echo "==> Built $APP"
