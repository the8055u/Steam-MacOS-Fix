#!/bin/sh
# Starts the Steam client with libsteamfix.dylib loaded. Steam's own files are not modified.
#
# Optional switches: create an empty file with one of these names next to the library
# (Contents/Resources) to change behaviour:
#   no-shape    keep Steam's square, borderless windows
#   no-stage    keep Steam Helper a background agent (no Stage Manager fix)
#   no-rename   do not share the Steam app's Dock tile (Steam shows a second tile of its own)
#   no-auto     the background agent leaves Steam alone when it is started the ordinary way
#   debug       write a log to ~/Library/Logs/SteamFix.log
RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
STEAM_DIR="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
STEAM="$STEAM_DIR/steam_osx"
STEAM_APP="/Applications/Steam.app"

# Steam not installed/bootstrapped yet: fall back to the stock launcher.
if [ ! -x "$STEAM" ] || [ ! -f "$RES/libsteamfix.dylib" ]; then
    exec open "$STEAM_APP"
fi

# Same environment the stock bootstrapper provides.
export STEAM_APP_BUNDLE_PATH="$STEAM_APP"
export STEAM_CLIENT_CONFIG_FILE="$STEAM_DIR/steam.cfg"
export LC_ALL="en_US.UTF-8"
[ -f "$RES/debug" ] && export STEAMFIX_DEBUG=1
[ -f "$RES/no-shape" ] && export STEAMFIX_SHAPE=0
[ -f "$RES/no-stage" ] && export STEAMFIX_STAGE=0
[ -f "$RES/no-rename" ] && export STEAMFIX_RENAME=0

cd "$STEAM_DIR" || exit 1
export DYLD_INSERT_LIBRARIES="$RES/libsteamfix.dylib"
exec "$STEAM" "$@"
