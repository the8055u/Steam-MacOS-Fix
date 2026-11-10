#!/bin/sh
# Builds everything into ./build:
#   build/Steam (fix).app/Contents/MacOS/launch                    src/launcher.sh
#   build/Steam (fix).app/Contents/Resources/libsteamfix.dylib     src/steamfix.m   (arm64 + x86_64)
#   build/Steam (fix).app/Contents/Resources/steamfix-agent        src/agent.swift
# Needs the Xcode command line tools (clang, swiftc). Nothing is downloaded and nothing outside
# ./build is written.
set -eu
cd "$(dirname "$0")/.."

for tool in clang swiftc lipo; do
    xcrun --find "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found — install the Xcode command line tools (xcode-select --install)" >&2; exit 1; }
done

OUT="build"
APP="$OUT/Steam (fix).app"
RES="$APP/Contents/Resources"
STEAM_ICON="/Applications/Steam.app/Contents/Resources/Steam.icns"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$RES"

# The library is loaded into Steam's processes, which are universal binaries: build both slices.
# _LSApplicationCheckIn is a LaunchServices symbol without a public header; it is resolved at load time.
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -fobjc-arc -Wall \
    -dynamiclib -framework AppKit -framework ApplicationServices -Wl,-U,__LSApplicationCheckIn \
    -o "$RES/libsteamfix.dylib" src/steamfix.m

xcrun swiftc -O src/agent.swift -o "$RES/steamfix-agent"

cp src/launcher.sh "$APP/Contents/MacOS/launch"
chmod +x "$APP/Contents/MacOS/launch"
# Only used by Finder for the launcher itself; optional.
[ -f "$STEAM_ICON" ] && cp "$STEAM_ICON" "$RES/Steam.icns"

# LSUIElement: the launcher only hands over to Steam and must not get a Dock tile of its own.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>launch</string>
    <key>CFBundleIdentifier</key><string>local.steamfix.launcher</string>
    <key>CFBundleName</key><string>Steam</string>
    <key>CFBundleDisplayName</key><string>Steam (fix)</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>Steam.icns</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "built: $APP  (library: $(lipo -archs "$RES/libsteamfix.dylib"))"
