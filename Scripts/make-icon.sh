#!/bin/bash
# Regenerates the app icon (Resources/AppIcon.icns).
set -euo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$T"
swift Scripts/make-icon.swift "$T"
iconutil -c icns "$T" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"
