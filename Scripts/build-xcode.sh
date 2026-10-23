#!/bin/bash
# Builds VoxFlowAir with the Xcode project (VoxFlowAir.xcodeproj): app, driver, tools.
# Usage: Scripts/build-xcode.sh [--debug] [--test]
#   --test: also runs the tests (engine under Xcode + driver without installing it)
#           and writes a report to $VOXFLOWAIR_DERIVED/test-reports/.
# Output: $VOXFLOWAIR_DERIVED/dist/VoxFlowAir.app (default ~/Library/Developer/VoxFlowAirXcode).
# Build products live outside the source tree.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${VOXFLOWAIR_DERIVED:-$HOME/Library/Developer/VoxFlowAirXcode}"
CONFIG=Release; TEST=0
for a in "$@"; do case "$a" in --debug) CONFIG=Debug;; --test) TEST=1;; esac; done
XB=(xcodebuild -project VoxFlowAir.xcodeproj -derivedDataPath "$DERIVED" -configuration "$CONFIG")
# Shows only errors, warnings and the result (xcodebuild -quiet wrongly reports
# "commands failed with exit code 0").
filter_output() { grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | grep -v "Metadata extraction skipped" | sort -u || true; }
PRODUCTS="$DERIVED/Build/Products/$CONFIG"

echo "▶︎ VoxFlowAirDriver driver + tests ($CONFIG)"
"${XB[@]}" -scheme VoxFlowAirDriver build 2>&1 | filter_output
echo "▶︎ VoxFlowAir app ($CONFIG, arm64)"
"${XB[@]}" -scheme VoxFlowAir build 2>&1 | filter_output
echo "▶︎ VoxFlowAirTool tool"
"${XB[@]}" -scheme VoxFlowAirTool build 2>&1 | filter_output

mkdir -p "$DERIVED/dist"
rm -rf "$DERIVED/dist/VoxFlowAir.app"
ditto "$PRODUCTS/VoxFlowAir.app" "$DERIVED/dist/VoxFlowAir.app"
codesign --verify --strict --deep "$DERIVED/dist/VoxFlowAir.app"
echo "✔︎ $DERIVED/dist/VoxFlowAir.app (valid local signature, embedded driver: Contents/Resources/Driver)"

if [ $TEST -eq 1 ]; then
  mkdir -p "$DERIVED/test-reports"
  OUT="$DERIVED/test-reports/xcode-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "VoxFlowAir — test report (Xcode project) $(date)"
    sw_vers; uname -m; xcodebuild -version | sed -n 1p
    echo; echo "== Engine tests (VoxFlowAirCoreTests, VoxFlowAir scheme) =="
    xcodebuild -project VoxFlowAir.xcodeproj -derivedDataPath "$DERIVED" -scheme VoxFlowAir test 2>&1 \
      | grep -E '✔|✘|Test run|TEST (SUCCEEDED|FAILED)|error:' | grep -vE 'started\.$'
    echo; echo "== Driver tests without installation (VoxFlowAirDriverTests) =="
    "$PRODUCTS/VoxFlowAirDriverTests" "$PRODUCTS/VoxFlowAirDriver.driver"
    if [ -d /Library/Audio/Plug-Ins/HAL/VoxFlowAirDriver.driver ]; then
      echo; echo "== Installed driver tests =="
      "$PRODUCTS/VoxFlowAirDriverTests" --installed || true
    fi
  } 2>&1 | tee "$OUT"
  echo "Report: $OUT"
fi
