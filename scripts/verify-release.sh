#!/bin/bash
# Inspect a locally downloaded VirtualDisplayCamera.app ZIP on macOS.
# Usage: bash scripts/verify-release.sh /path/to/VirtualDisplayCamera.zip
set -euo pipefail

ZIP="${1:-}"
if [[ -z "$ZIP" || ! -f "$ZIP" ]]; then
  echo 'Usage: bash scripts/verify-release.sh "/path/to/VirtualDisplayCamera.zip"' >&2
  exit 2
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto -x -k "$ZIP" "$STAGE"
APP="$(find "$STAGE" -name 'VirtualDisplayCamera.app' -type d -print -quit)"

if [[ -z "$APP" ]]; then
  echo 'ERROR: ZIP does not contain VirtualDisplayCamera.app' >&2
  exit 1
fi

EXE="$APP/Contents/MacOS/VirtualDisplayCamera"
if [[ ! -f "$EXE" ]]; then
  echo 'ERROR: Application executable is missing.' >&2
  exit 1
fi

echo '=== Application executable ==='
file "$EXE"
echo
echo '=== Minimum supported macOS (minos) ==='
xcrun vtool -show-build "$EXE"
echo
echo '=== Embedded Syphon framework ==='
if [[ -f "$APP/Contents/Frameworks/Syphon.framework/Syphon" ]]; then
  echo 'PASS: Syphon.framework is embedded.'
else
  echo 'ERROR: Syphon.framework executable is not embedded.' >&2
  exit 1
fi
echo
echo '=== Syphon dynamic-link reference ==='
otool -L "$EXE" | grep 'Syphon.framework' || echo 'WARNING: No direct Syphon framework reference found in the executable.'
echo
echo '=== Bundled icon resources ==='
if [[ -f "$APP/Contents/Resources/Assets.car" ]]; then
  echo 'Asset catalog found. Look for an AppIcon entry below:'
  xcrun --find assetutil >/dev/null 2>&1 && xcrun assetutil --info "$APP/Contents/Resources/Assets.car" | grep -m 3 -A 2 '"Name" : "AppIcon"' || true
else
  echo 'No Assets.car found; check for a bundled .icns file.'
  find "$APP/Contents/Resources" -maxdepth 1 -name '*.icns' -print || true
fi
echo
echo '=== Code signature ==='
if codesign --verify --deep --strict --verbose=2 "$APP"; then
  echo 'PASS: App bundle signature verifies locally.'
else
  echo 'WARNING: Signature failed local verification. This is separate from notarization.'
fi
echo
echo 'Done. This inspection does NOT confirm successful operation on Sequoia or notarization.'
