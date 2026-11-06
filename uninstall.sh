#!/bin/sh
# Quits Spamurai and removes the app and its login item. Settings and history are kept unless you pass --all.
osascript -e 'tell application id "com.spamurai.app" to quit' >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)/com.spamurai.agent" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.spamurai.agent.plist"
rm -rf "$HOME/Applications/Spamurai.app"
if [ "${1:-}" = "--all" ]; then rm -rf "$HOME/Library/Application Support/Spamurai" "$HOME/Library/Logs/Spamurai"; fi
echo "Spamurai removed. Also remove it from System Settings > Privacy & Security > Full Disk Access."
