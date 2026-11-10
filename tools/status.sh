#!/bin/sh
# Shows whether steamfix is installed and whether the running Steam has it. Read-only.
# Exit status: 0 everything as expected, 1 something is off, 2 Steam is not running.
. "$(dirname "$0")/lib.sh"
bad=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; bad=1; }
note() { printf '        %s\n' "$1"; }

echo "Installation"
[ -x "$APP/Contents/MacOS/launch" ] && ok "launcher" || fail "launcher missing: $APP"
if [ -f "$RES/libsteamfix.dylib" ]; then ok "library ($(lipo -archs "$RES/libsteamfix.dylib" 2>/dev/null))"; else fail "library missing"; fi
[ -x "$RES/steamfix-agent" ] && ok "agent binary" || fail "agent binary missing"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    pgrep -f "steamfix-agent" >/dev/null && ok "agent loaded and running" || fail "agent loaded but not running"
else
    fail "agent not loaded (launchctl: $LABEL)"
fi
for f in no-shape no-stage no-rename no-auto debug; do [ -f "$RES/$f" ] && note "switch set: $f"; done

echo "Steam"
clients="$(client_pids)"
if [ -z "$clients" ]; then
    note "not running — start it the usual way and run this again"
    [ "$bad" = 0 ] && exit 2 || exit 1
fi
for p in $clients; do
    if has_fix "$p"; then ok "client $p started through the launcher"; else fail "client $p runs WITHOUT the fix"; fi
done
h="$(helper_pid)"
if [ -n "$h" ]; then
    asn="$(lsappinfo find pid="$h" | head -1)"
    info="$(lsappinfo info -only bundlepath,applicationtype "$asn" 2>/dev/null | tr '\n' ' ')"
    case "$info" in *'"Foreground"'*) ok "window process $h is a regular app (Stage Manager can manage it)";; *) fail "window process $h is not a regular app: $info";; esac
    if [ -f "$RES/no-rename" ]; then note "no-rename is set: Steam keeps a Dock tile of its own"
    else case "$info" in *"$STEAM_APP"*) ok "window process is registered as $STEAM_APP (one Dock tile)";; *) fail "window process is not registered as $STEAM_APP: $info";; esac
    fi
else
    fail "no Steam Helper browser process found"
fi

# The library must be in exactly two processes: the client and the helper's browser process.
carriers=0; total=0
for p in $(pgrep -f "Steam.AppBundle/Steam/Contents/"); do
    total=$((total + 1)); ps eww -o command= -p "$p" 2>/dev/null | grep -q "DYLD_INSERT_LIBRARIES" && carriers=$((carriers + 1))
done
[ "$carriers" = 2 ] && ok "library present in 2 of $total Steam processes (client + window process only)" \
                    || fail "library present in $carriers of $total Steam processes (expected 2)"

tiles="$(osascript -e 'tell application "System Events" to tell process "Dock" to get {name, value of attribute "AXIsApplicationRunning"} of (every UI element of list 1 whose name contains "Steam")' 2>/dev/null)"
if [ -n "$tiles" ]; then
    n="$(printf '%s' "$tiles" | tr ',' '\n' | grep -c "Steam")"
    [ "$n" = 1 ] && ok "one Steam tile in the Dock ($tiles)" || fail "$n Steam tiles in the Dock ($tiles)"
else
    note "Dock not inspected (needs permission to control System Events)"
fi

if w="$(tool wins)"; then
    echo "Windows (pid id on-screen x y width height title)"
    "$w" | sed 's/^/        /'
fi
exit $bad
