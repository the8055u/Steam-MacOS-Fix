# Shared by the tools; sourced, not run.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Library/Application Support/SteamFix/Steam (fix).app"
RES="$APP/Contents/Resources"
LABEL="local.steamfix.agent"
STEAM_APP="/Applications/Steam.app"
CLIENT_PATTERN="Steam.AppBundle/Steam/Contents/MacOS/steam_osx$"
HELPER_PATTERN="Steam Helper -nocrashdialog"

# Compiles a Swift tool into build/tools on first use and prints its path.
tool() {
    out="$ROOT/build/tools/$1"
    if [ ! -x "$out" ] || [ "$ROOT/tools/$1.swift" -nt "$out" ]; then
        mkdir -p "$ROOT/build/tools"
        xcrun swiftc -O "$ROOT/tools/$1.swift" -o "$out" 2>/dev/null || { echo "could not build tools/$1.swift" >&2; return 1; }
    fi
    echo "$out"
}

client_pids() { pgrep -f "$CLIENT_PATTERN"; }
helper_pid() { pgrep -f "$HELPER_PATTERN" | head -1; }
has_fix() { ps eww -o command= -p "$1" 2>/dev/null | grep -q "libsteamfix"; }
