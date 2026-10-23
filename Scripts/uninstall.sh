#!/bin/bash
# Uninstalls VoxFlowAir. By default, presets and settings are kept.
# Usage: Scripts/uninstall.sh [--purge]   (--purge: also deletes presets, settings and logs, after confirmation)
# BlackHole is never removed automatically (other apps may use it).
set -uo pipefail
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1

APP_ID=""
for d in /Applications/VoxFlowAir.app "$HOME/Applications/VoxFlowAir.app"; do
  [ -z "$APP_ID" ] && [ -d "$d" ] && APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$d/Contents/Info.plist" 2>/dev/null)"
done
osascript -e 'tell application "VoxFlowAir" to quit' >/dev/null 2>&1 || true
sleep 1
for d in /Applications/VoxFlowAir.app "$HOME/Applications/VoxFlowAir.app"; do
  if [ -d "$d" ]; then
    echo "Removing $d (to the Trash)"
    osascript -e "tell application \"Finder\" to delete POSIX file \"$d\"" >/dev/null 2>&1 || rm -rf "$d"
  fi
done
# Removes the login item, if any (managed by macOS through SMAppService):
echo "If VoxFlowAir was listed in System Settings › General › Login Items, the entry goes away with the app."

if [ $PURGE -eq 1 ]; then
  read -r -p "Permanently delete VoxFlowAir presets, settings and logs? [y/N] " a
  if [[ "$a" =~ ^(y|Y|yes)$ ]]; then
    rm -rf "$HOME/Library/Application Support/VoxFlowAir" "$HOME/Library/Logs/VoxFlowAir"
    echo "VoxFlowAir data deleted."
  fi
else
  echo "Presets and settings kept in ~/Library/Application Support/VoxFlowAir (run again with --purge to delete them)."
fi
[ -n "$APP_ID" ] && tccutil reset Microphone "$APP_ID" >/dev/null 2>&1 && echo "VoxFlowAir microphone permission reset."
echo
echo "BlackHole was not removed (other apps may use it)."
echo "To remove it: brew uninstall --cask blackhole-2ch  (or delete /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver, then restart)."
