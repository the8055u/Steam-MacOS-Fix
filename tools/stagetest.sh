#!/bin/sh
# Checks that Stage Manager manages Steam's windows: brings Steam to the front, then switches back
# to the app that was in front, and looks at where Steam's windows ended up.
# NOTE: this switches apps on screen for a few seconds. Steam must be running with a window open.
# Exit status: 0 managed, 1 not managed, 2 could not run the test.
. "$(dirname "$0")/lib.sh"

[ "$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null)" = 1 ] || { echo "Stage Manager is off — nothing to test"; exit 2; }
[ -n "$(client_pids)" ] || { echo "Steam is not running"; exit 2; }
w="$(tool wins)" || exit 2

front_asn="$(lsappinfo front)"
front_id="$(lsappinfo info -only bundleid "$front_asn" | grep -o 'bundleID="[^"]*"' | head -1 | sed -E 's/.*="(.*)"/\1/')"
front_name="$(lsappinfo info -only name "$front_asn" | head -1 | sed -E 's/^"([^"]*)".*/\1/')"
case "$front_name" in Steam*) echo "Steam is frontmost: put another app with a window in front and run again"; exit 2;; esac
[ -n "$front_id" ] || { echo "could not identify the frontmost app"; exit 2; }

# A window parked in the Stage Manager strip is reported at thumbnail size (about 120 pt wide).
width() { "$w" | awk '$3 == 1 && $6 > m { m = $6 } END { print m + 0 }'; }

open "$STEAM_APP"
osascript -e "tell application \"$STEAM_APP\" to activate" >/dev/null 2>&1
sleep 3
w_front="$(width)"
if [ "$w_front" -le 300 ]; then
    echo "could not bring Steam to the front (macOS only lets the active app hand over focus):"
    echo "run this from the app that is currently in front, with a Steam window open"
    exit 2
fi
osascript -e "tell application id \"$front_id\" to activate" >/dev/null 2>&1
sleep 3
w_back="$(width)"

echo "Steam in front:        widest Steam window on screen ${w_front} pt"
echo "$front_name in front:  widest Steam window on screen ${w_back} pt"
if [ "$w_back" -le 300 ]; then
    echo "ok: Stage Manager moved Steam's windows to the strip"
else
    echo "FAIL: Steam's windows stayed on screen when another app came to the front"; exit 1
fi
