#!/bin/bash
# VoxFlowAir — installs the BlackHole 2ch virtual output (Existential Audio, GPL-3.0).
# Official source: https://existential.audio/blackhole/ — through Homebrew (SHA-256 checksum verified).
# This script turns off no macOS protection. Your password is asked for by macOS/Homebrew, not by VoxFlowAir.
set -u
echo "=== VoxFlowAir: installing BlackHole 2ch ==="
HAL="/Library/Audio/Plug-Ins/HAL"
if ls "$HAL"/BlackHole*.driver >/dev/null 2>&1; then
  echo "BlackHole is already installed:"
  for d in "$HAL"/BlackHole*.driver; do
    v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$d/Contents/Info.plist" 2>/dev/null)
    echo "  - $(basename "$d") version $v"
  done
  echo "Nothing to do. You can close this window."
  exit 0
fi

BREW=""
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && BREW="$b" && break; done
if [ -z "$BREW" ]; then
  echo "Homebrew is not installed."
  echo "Option 1: install Homebrew (https://brew.sh), then run this script again."
  echo "Option 2: download \"BlackHole 2ch\" from https://existential.audio/blackhole/ and open the .pkg."
  open "https://existential.audio/blackhole/"
  exit 1
fi

echo "Homebrew found: $BREW"
echo "License: BlackHole is distributed under GPL-3.0 (https://github.com/ExistentialAudio/BlackHole)."
read -r -p "Install BlackHole 2ch now? [y/N] " ans
case "$ans" in y|Y|yes) ;; *) echo "Cancelled."; exit 1;; esac

"$BREW" install --cask blackhole-2ch || { echo "Installation FAILED. See the messages above."; exit 1; }

echo
echo "Checking…"
if ls "$HAL"/BlackHole2ch.driver >/dev/null 2>&1; then
  echo "Driver present: $HAL/BlackHole2ch.driver"
else
  echo "WARNING: driver not found in $HAL."
  exit 1
fi
sleep 2
if system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole"; then
  echo "OK: the \"BlackHole 2ch\" device is published by macOS."
  echo "Go back to VoxFlowAir and click \"Check\"."
else
  echo "The driver is installed but macOS does not publish it yet."
  echo "Restart the audio service (sudo killall coreaudiod) or restart the Mac, then click \"Check\" in VoxFlowAir."
fi
