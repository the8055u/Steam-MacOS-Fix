#!/bin/sh
# Removes everything scripts/install.sh put on this Mac: the agent, the launcher with the library,
# and the logs. Steam itself was never modified, so there is nothing to restore — quit Steam and
# start it again the usual way.
LABEL="local.steamfix.agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/SteamFix" "$HOME/Applications/Steam (fix).app"
rm -f "$HOME/Library/Logs/SteamFix.log" "$HOME/Library/Logs/SteamFix-agent.log"
echo "steamfix removed"
if pgrep -f "Steam.AppBundle/Steam/Contents/MacOS/steam_osx" >/dev/null 2>&1; then
    echo "Steam is still running with the old library loaded: quit it and start it again."
fi
