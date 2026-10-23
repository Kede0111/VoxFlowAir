#!/bin/bash
# VoxFlowAir — installs the "VoxFlowAir Micro" virtual audio device (VoxFlowAirDriver driver).
#
# What this script does, and nothing else:
#   1. checks the system and the driver signature;
#   2. copies VoxFlowAirDriver.driver into /Library/Audio/Plug-Ins/HAL (administrator rights:
#      macOS asks for your password, VoxFlowAir never sees it);
#   3. restarts the macOS audio service (coreaudiod) so it loads the driver:
#      all Mac audio stops for 2 to 5 seconds;
#   4. checks that "VoxFlowAir Micro" is published.
# No macOS protection is turned off; BlackHole and your plugins are left alone.
#
# Usage: install-voxflowair-driver.command [path/to/VoxFlowAirDriver.driver]
set -u
HAL="/Library/Audio/Plug-Ins/HAL"
DEST="$HAL/VoxFlowAirDriver.driver"
HERE="$(cd "$(dirname "$0")" && pwd)"

fail() { echo; echo "FAILED: $*"; exit 1; }

echo "=== VoxFlowAir: installing the \"VoxFlowAir Micro\" virtual microphone ==="

# 1. System
OSV="$(sw_vers -productVersion)"; MAJOR="${OSV%%.*}"
[ "$MAJOR" -ge 26 ] 2>/dev/null || fail "macOS 26 or later required (current: $OSV)."
echo "macOS $OSV ($(uname -m)): compatible."

# 2. Driver to install
SRC="${1:-}"
if [ -z "$SRC" ]; then
  for c in "$HERE/Driver/VoxFlowAirDriver.driver" "$HERE/VoxFlowAirDriver.driver"; do [ -d "$c" ] && SRC="$c" && break; done
fi
[ -n "$SRC" ] && [ -d "$SRC" ] || fail "VoxFlowAirDriver.driver not found (pass its path as an argument)."
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist" 2>/dev/null)"
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SRC/Contents/Info.plist" 2>/dev/null)"
[ "$EXE" = "VoxFlowAirDriver" ] && [[ "$ID" == *.driver ]] || fail "$SRC is not the VoxFlowAir driver (identifier \"$ID\")."
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist")"
codesign --verify --strict "$SRC" 2>/dev/null || fail "invalid driver signature: $SRC"
echo "Driver: $SRC (version $VER, valid local signature)."
if [ -d "$DEST" ]; then
  OLD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null)"
  echo "Version already installed: $OLD (it will be replaced)."
fi

echo
echo "The macOS audio service will restart: audio in every app will stop for a few"
echo "seconds (OBS, FaceTime and VoxFlowAir then resume on their own or after the device"
echo "is selected again)."
read -r -p "Install now? [y/N] " ans
case "$ans" in y|Y|yes) ;; *) echo "Cancelled, nothing was changed."; exit 1;; esac

echo "macOS will ask for your administrator password."
sudo -v || fail "administrator authorization denied, nothing was changed."

# 3. Copy and permissions
sudo mkdir -p "$HAL" || fail "could not create $HAL."
sudo rm -rf "$DEST.tmp"
sudo ditto "$SRC" "$DEST.tmp" || fail "could not copy."
sudo xattr -cr "$DEST.tmp"
sudo chown -R root:wheel "$DEST.tmp" && sudo chmod -R go-w "$DEST.tmp"
sudo rm -rf "$DEST" && sudo mv "$DEST.tmp" "$DEST" || fail "could not move into place."
echo "Driver copied to $DEST."

# 4. Reload by coreaudiod
echo "Restarting the audio service…"
sudo killall coreaudiod 2>/dev/null
sleep 2

# 5. Check
for i in $(seq 1 15); do
  if system_profiler SPAudioDataType 2>/dev/null | grep -q "VoxFlowAir Micro"; then
    echo
    echo "OK: \"VoxFlowAir Micro\" is published by macOS."
    echo "In VoxFlowAir: Settings › Audio › Virtual output › \"VoxFlowAir Micro (VoxFlowAir driver)\"."
    echo "In OBS, FaceTime…: choose the \"VoxFlowAir Micro\" microphone."
    exit 0
  fi
  sleep 1
done

echo
echo "The driver is installed but macOS does not publish \"VoxFlowAir Micro\"."
echo "--- Diagnostic ---"
ls -le "$DEST" "$DEST/Contents/MacOS" 2>&1
codesign -dv "$DEST" 2>&1 | grep -E "Identifier|Signature|flags"
log show --last 2m --style compact --predicate 'process == "coreaudiod" || subsystem == "'"$ID"'"' 2>/dev/null | grep -iE "voxflowair|plug-?in|driver" | tail -20
echo "Try restarting the Mac. To remove the driver: uninstall-voxflowair-driver.command"
exit 2
