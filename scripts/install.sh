#!/bin/sh
# Builds and installs steamfix for the current user. Safe to run again (it replaces the old copy).
#
#   ~/Library/Application Support/SteamFix/Steam (fix).app   launcher + library + agent
#   ~/Library/LaunchAgents/local.steamfix.agent.plist        starts the agent at login
#
# The launcher is deliberately kept out of the Applications folders: with the agent running, the
# ordinary Steam icon leads to the fixed Steam, so there is only one "Steam" to click.
# Steam's own files are not touched. Undo with scripts/uninstall.sh.
set -eu
cd "$(dirname "$0")/.."
sh scripts/build.sh

DEST="$HOME/Library/Application Support/SteamFix"
APP="$DEST/Steam (fix).app"
LABEL="local.steamfix.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

mkdir -p "$DEST" "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

# Keep the user's switch files (no-shape, no-stage, no-rename, no-auto, debug) across reinstalls.
KEEP="$(mktemp -d)"
for f in no-shape no-stage no-rename no-auto debug; do
    [ -f "$APP/Contents/Resources/$f" ] && touch "$KEEP/$f"
done
rm -rf "$APP"
cp -R "build/Steam (fix).app" "$DEST/"
for f in "$KEEP"/*; do [ -f "$f" ] && touch "$APP/Contents/Resources/$(basename "$f")"; done
rm -rf "$KEEP"

# Left behind by earlier versions of this project.
rm -rf "$HOME/Applications/Steam (fix).app" "$DEST/helper.noindex"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/Resources/steamfix-agent</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Background</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST_EOF
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "installed: $APP"
echo "agent:     $LABEL loaded"
if pgrep -f "Steam.AppBundle/Steam/Contents/MacOS/steam_osx" >/dev/null 2>&1; then
    echo "Steam is running: quit it and start it again the usual way to pick up this build."
else
    echo "Start Steam the usual way; check the result with: make status"
fi
