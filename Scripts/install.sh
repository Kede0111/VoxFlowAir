#!/bin/bash
# Installs VoxFlowAir.app into /Applications (or ~/Applications) and checks the virtual output.
# Usage: Scripts/install.sh [--user]   (--user: installs into ~/Applications, no admin rights)
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${VOXFLOWAIR_DERIVED:-$HOME/Library/Developer/VoxFlowAirXcode}"
SRC="$DERIVED/dist/VoxFlowAir.app"
DEST_DIR="/Applications"
[ "${1:-}" = "--user" ] && DEST_DIR="$HOME/Applications"

if [ ! -d "$SRC" ]; then
  echo "VoxFlowAir.app is not built yet: running Scripts/build-xcode.sh"
  bash Scripts/build-xcode.sh
fi

mkdir -p "$DEST_DIR"
if pgrep -x VoxFlowAir >/dev/null; then
  echo "VoxFlowAir is running: quitting it…"
  osascript -e 'tell application "VoxFlowAir" to quit' >/dev/null 2>&1 || true
  sleep 2
fi
echo "▶︎ Copying to $DEST_DIR/VoxFlowAir.app"
rm -rf "$DEST_DIR/VoxFlowAir.app"
ditto "$SRC" "$DEST_DIR/VoxFlowAir.app"
codesign --verify --strict "$DEST_DIR/VoxFlowAir.app" && echo "✔︎ Valid local signature"

echo
if ls /Library/Audio/Plug-Ins/HAL/BlackHole*.driver >/dev/null 2>&1; then
  echo "✔︎ BlackHole virtual output present."
else
  echo "⚠︎ BlackHole is not installed: VoxFlowAir will work (monitoring) but no app will be able to receive the audio."
  echo "  Install it from VoxFlowAir (\"Install Virtual Output…\" banner) or with:"
  echo "    Resources/install-blackhole.command"
fi
echo
echo "First launch: macOS will ask for microphone access. If Gatekeeper blocks the app"
echo "(not notarized), open System Settings › Privacy & Security and click “Open Anyway”, just once."
open "$DEST_DIR/VoxFlowAir.app"
