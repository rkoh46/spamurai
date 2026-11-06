#!/bin/sh
# Quits Callwatch and removes the app and its login item. Settings and history are kept unless you pass --all.
osascript -e 'tell application id "com.callwatch.app" to quit' >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)/com.callwatch.agent" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.callwatch.agent.plist"
rm -rf "$HOME/Applications/Callwatch.app"
if [ "${1:-}" = "--all" ]; then rm -rf "$HOME/Library/Application Support/Callwatch" "$HOME/Library/Logs/Callwatch"; fi
echo "Callwatch removed. Also remove it from System Settings > Privacy & Security > Full Disk Access."
