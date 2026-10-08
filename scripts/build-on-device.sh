#!/bin/bash
# build-on-device.sh — build loopl, install on a connected iPhone, launch.
# Pattern from tinyai-id/ios/scripts/build-on-device.sh (core team: K6B7JDYLLL).
#   DEVICE_ID=<udid>  DEVELOPMENT_TEAM=XXXXXXXXXX  DERIVED=/tmp/dd-loopl-device  ./scripts/build-on-device.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE_ID="${DEVICE_ID:-$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ {print $3; exit}')}"
[ -n "$DEVICE_ID" ] || { echo "✗ no connected iPhone (plug in + unlock)"; exit 1; }
TEAM="${DEVELOPMENT_TEAM:-K6B7JDYLLL}"
DERIVED="${DERIVED:-/tmp/dd-loopl-device}"
APP_ID="technology.tiny.loopl"
xcodegen generate -s App/project.yml >/dev/null   # ALWAYS regenerate: a stale .xcodeproj in a long-lived worktree misses new Swift files (CI regenerates each run, so only deploys ever saw it)
echo "▸ building for $DEVICE_ID (team $TEAM)…"
xcodebuild -project App/LooplApp.xcodeproj -scheme loopl -destination "id=$DEVICE_ID" -configuration Debug \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -skipPackagePluginValidation -skipMacroValidation DEVELOPMENT_TEAM="$TEAM" build
APP="$DERIVED/Build/Products/Debug-iphoneos/loopl.app"
[ -d "$APP" ] || { echo "✗ $APP missing"; exit 1; }
echo "▸ installing (keep the phone unlocked)…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
echo "▸ launching…"
xcrun devicectl device process launch --device "$DEVICE_ID" "$APP_ID" || echo "(launch failed — device locked? open loopl by hand)"
