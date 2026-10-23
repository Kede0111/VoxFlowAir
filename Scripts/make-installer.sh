#!/bin/bash
# Builds the VoxFlowAir installer from the build made by Scripts/build-xcode.sh:
#   VoxFlowAir-<version>.pkg: installs VoxFlowAir.app into /Applications and, optionally (checked by
#                          default), the "VoxFlowAir Micro" virtual microphone into /Library/Audio/Plug-Ins/HAL;
#   VoxFlowAir-<version>.dmg: disk image to keep, with the .pkg, the uninstallers and a read-me.
# BlackHole is not included (VoxFlowAir offers to install it on first launch).
# Usage: Scripts/make-installer.sh [output folder]   (default: $VOXFLOWAIR_DERIVED/installer)
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${VOXFLOWAIR_DERIVED:-$HOME/Library/Developer/VoxFlowAirXcode}"
APP="$DERIVED/dist/VoxFlowAir.app"
DRIVER="$APP/Contents/Resources/Driver/VoxFlowAirDriver.driver"
OUT="${1:-$DERIVED/installer}"
[ -d "$APP" ] || { echo "VoxFlowAir.app not found: run Scripts/build-xcode.sh first"; exit 1; }
[ -d "$DRIVER" ] || { echo "Driver missing from $APP"; exit 1; }
codesign --verify --strict --deep "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
NAME="VoxFlowAir-$VERSION"

# Work in a temporary folder outside the source tree (some file systems add stray "._*" files).
WORK="$(mktemp -d "${TMPDIR:-/tmp}/voxflowair-installer.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"/{app/Applications,driver/Library/Audio/Plug-Ins/HAL,scripts-app,scripts-driver,resources,pkgs,dmg}
ditto --norsrc "$APP" "$WORK/app/Applications/VoxFlowAir.app"
ditto --norsrc "$DRIVER" "$WORK/driver/Library/Audio/Plug-Ins/HAL/VoxFlowAirDriver.driver"
# No extended attributes: pkgbuild would embed them as "._*" files.
xattr -cr "$WORK/app" "$WORK/driver"

# Scripts run by Installer (as root).
cat > "$WORK/scripts-app/preinstall" <<'EOF'
#!/bin/bash
# Quits VoxFlowAir if it is running, so the new version cleanly replaces the old one.
USER_ID="$(stat -f %u /dev/console)"
if pgrep -x VoxFlowAir >/dev/null; then
  launchctl asuser "$USER_ID" osascript -e 'tell application "VoxFlowAir" to quit' >/dev/null 2>&1 || true
  sleep 2
  pkill -x VoxFlowAir 2>/dev/null || true
fi
exit 0
EOF
cat > "$WORK/scripts-driver/postinstall" <<'EOF'
#!/bin/bash
# Reloads the audio service to publish "VoxFlowAir Micro" (Mac audio stops for a few seconds).
DEST="/Library/Audio/Plug-Ins/HAL/VoxFlowAirDriver.driver"
xattr -cr "$DEST" 2>/dev/null
chown -R root:wheel "$DEST" && chmod -R go-w "$DEST"
killall coreaudiod 2>/dev/null || true
exit 0
EOF
chmod 755 "$WORK"/scripts-*/*

# Packages: never "relocatable", otherwise Installer would update another copy of
# VoxFlowAir.app found on disk (DerivedData…) instead of installing into /Applications.
build_component() { # root identifier scripts output
  pkgbuild --analyze --root "$1" "$WORK/$2.plist" >/dev/null
  local i=0 key
  while /usr/libexec/PlistBuddy -c "Print :$i" "$WORK/$2.plist" >/dev/null 2>&1; do
    # Always install, even over an equal or newer version.
    for key in BundleIsRelocatable BundleIsVersionChecked; do
      /usr/libexec/PlistBuddy -c "Delete :$i:$key" "$WORK/$2.plist" >/dev/null 2>&1 || true
      /usr/libexec/PlistBuddy -c "Add :$i:$key bool false" "$WORK/$2.plist"
    done
    i=$((i + 1))
  done
  pkgbuild --root "$1" --component-plist "$WORK/$2.plist" --identifier "$2" --version "$VERSION" \
    --install-location / --ownership recommended --scripts "$3" "$4" >/dev/null
}
build_component "$WORK/app" $APP_ID.app "$WORK/scripts-app" "$WORK/pkgs/VoxFlowAirApp.pkg"
build_component "$WORK/driver" $APP_ID.driver "$WORK/scripts-driver" "$WORK/pkgs/VoxFlowAirDriver.pkg"

# Text shown by Installer.
cat > "$WORK/resources/welcome.html" <<EOF
<html><body style="font-family:-apple-system;font-size:13px">
<h2>VoxFlowAir $VERSION</h2>
<p>Real-time voice processing (Audio Unit plugins) for OBS, FaceTime and your other apps.</p>
<p>This installer puts <b>VoxFlowAir</b> in the Applications folder and, if you leave it checked,
the <b>“VoxFlowAir Micro”</b> virtual microphone. The Mac audio service restarts at the end:
audio stops for a few seconds.</p>
<p>Your presets and settings are kept when you update.</p>
<p style="color:gray">© 2026 Quentin Descotte. Created by Quentin Descotte.</p>
</body></html>
EOF
cat > "$WORK/resources/conclusion.html" <<EOF
<html><body style="font-family:-apple-system;font-size:13px">
<h2>VoxFlowAir is installed</h2>
<p>Open VoxFlowAir from the Applications folder. macOS asks for microphone access on first launch.</p>
<p>Output to other apps: <b>BlackHole 2ch</b> (default; VoxFlowAir offers to install it if it is
missing) or <b>VoxFlowAir Micro</b> (Settings › Audio › Virtual output). In OBS or FaceTime,
choose that device as the microphone.</p>
</body></html>
EOF

cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>VoxFlowAir $VERSION</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="allow" require-scripts="false" hostArchitectures="arm64"/>
  <domains enable_localSystem="true" enable_anywhere="false" enable_currentUserHome="false"/>
  <volume-check><allowed-os-versions><os-version min="26.0"/></allowed-os-versions></volume-check>
  <choices-outline>
    <line choice="app"/>
    <line choice="driver"/>
  </choices-outline>
  <choice id="app" title="VoxFlowAir" description="The app, in /Applications." enabled="false" selected="true">
    <pkg-ref id="$APP_ID.app"/>
  </choice>
  <choice id="driver" title="“VoxFlowAir Micro” virtual microphone" description="Optional audio driver, in /Library/Audio/Plug-Ins/HAL. BlackHole remains the default VoxFlowAir output." selected="true">
    <pkg-ref id="$APP_ID.driver"/>
  </choice>
  <pkg-ref id="$APP_ID.app" version="$VERSION">VoxFlowAirApp.pkg</pkg-ref>
  <pkg-ref id="$APP_ID.driver" version="$VERSION">VoxFlowAirDriver.pkg</pkg-ref>
</installer-gui-script>
EOF

mkdir -p "$OUT"
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" \
  --package-path "$WORK/pkgs" "$OUT/$NAME.pkg" >/dev/null
echo "✔︎ $OUT/$NAME.pkg"

# Disk image to keep: installer, uninstallers, read-me.
cp "$OUT/$NAME.pkg" "$WORK/dmg/Install VoxFlowAir $VERSION.pkg"
cp Scripts/uninstall.sh "$WORK/dmg/Uninstall VoxFlowAir.command"
cp Resources/uninstall-voxflowair-driver.command "$WORK/dmg/Uninstall VoxFlowAir Micro.command"
chmod 755 "$WORK/dmg/"*.command
cat > "$WORK/dmg/Read Me.txt" <<EOF
VoxFlowAir $VERSION — © 2026 Quentin Descotte

INSTALL
  Double-click "Install VoxFlowAir $VERSION.pkg" and follow the steps.
  The app goes into /Applications; the "VoxFlowAir Micro" virtual microphone is checked by default
  (use the "Customize" button to uncheck it). macOS asks for an administrator password.
  To update, run a newer installer: presets and settings are kept.

IF macOS BLOCKS THE INSTALLER (copy downloaded or received from someone else)
  VoxFlowAir is not notarized by Apple. Open System Settings › Privacy & Security,
  then click "Open Anyway" next to the installer, just once.

FIRST LAUNCH
  macOS asks for microphone access: it is required.
  Output to OBS, FaceTime…: BlackHole 2ch (VoxFlowAir offers to install it if it is missing)
  or "VoxFlowAir Micro" (Settings › Audio › Virtual output). Choose it as the microphone in the other app.

UNINSTALL
  "Uninstall VoxFlowAir.command": removes the app (presets are kept).
  "Uninstall VoxFlowAir Micro.command": removes the virtual microphone.
  Right-click › Open if macOS refuses to launch them with a double-click.

Requirements: Apple Silicon Mac, macOS 26 or later.
EOF
rm -f "$OUT/$NAME.dmg"
hdiutil create -quiet -volname "VoxFlowAir $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO "$OUT/$NAME.dmg"
echo "✔︎ $OUT/$NAME.dmg"
