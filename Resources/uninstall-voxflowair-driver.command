#!/bin/bash
# VoxFlowAir — uninstalls the "VoxFlowAir Micro" virtual microphone.
# Removes only /Library/Audio/Plug-Ins/HAL/VoxFlowAirDriver.driver, after checking its
# identifier. BlackHole, Audio Unit plugins, presets and settings are left alone.
set -u
DEST="/Library/Audio/Plug-Ins/HAL/VoxFlowAirDriver.driver"
echo "=== VoxFlowAir: uninstalling the \"VoxFlowAir Micro\" virtual microphone ==="
if [ ! -d "$DEST" ]; then echo "The VoxFlowAir driver is not installed. Nothing to do."; exit 0; fi
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null)"
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$DEST/Contents/Info.plist" 2>/dev/null)"
if [ "$EXE" != "VoxFlowAirDriver" ] || [[ "$ID" != *.driver ]]; then echo "FAILED: $DEST does not have the expected identifier ($ID). Nothing was removed."; exit 1; fi
echo "Apps using \"VoxFlowAir Micro\" will lose this microphone; Mac audio will stop for a few seconds."
read -r -p "Uninstall? [y/N] " ans
case "$ans" in y|Y|yes) ;; *) echo "Cancelled."; exit 1;; esac
sudo -v || { echo "Authorization denied, nothing was changed."; exit 1; }
sudo rm -rf "$DEST" || { echo "Removal FAILED."; exit 1; }
sudo killall coreaudiod 2>/dev/null
sleep 3
if system_profiler SPAudioDataType 2>/dev/null | grep -q "VoxFlowAir Micro"; then
  echo "The file is removed but macOS still publishes \"VoxFlowAir Micro\": restart the Mac."
else
  echo "OK: VoxFlowAir driver removed."
fi
