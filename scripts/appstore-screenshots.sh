#!/usr/bin/env bash
# App Store screenshots from the simulator using the DEBUG `--design-fixture` scenes.
#   scripts/appstore-screenshots.sh [--skip-build]
# Output: App/AppStore/<size>/NN-<scene>.png  (6.9" 1320×2868 from iPhone 17 Pro Max · 6.5" 1242×2688 from iPhone 11 Pro Max · ipad13 2064×2752 from iPad Pro 13")
# plus App/AppStore/<size>/framed/*.png captions when ImageMagick (`magick`) is present.
set -euo pipefail
cd "$(dirname "$0")/.."
DD=${DD:-/tmp/dd-appstore-shots}
OUT=App/AppStore
RUNTIME_26=$(xcrun simctl list runtimes | awk '/iOS 26/ {print $NF}' | tail -1)
RUNTIME_18=$(xcrun simctl list runtimes | awk '/iOS 18/ {print $NF}' | tail -1)

sim_for() { # name devicetype runtime → udid (create once)
  local name=$1 type=$2 rt=$3 udid
  udid=$(xcrun simctl list devices | awk -v n="$name" '$0 ~ "^ *"n" \\(" {gsub(/[()]/,"",$2); print $2; exit}')
  if [ -z "$udid" ]; then udid=$(xcrun simctl create "$name" "$type" "$rt"); fi
  echo "$udid"
}

UD69=$(sim_for appstore-69 com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max "$RUNTIME_26")
UD13=""
IPAD_TYPE=$(xcrun simctl list devicetypes | grep -o 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M[0-9]*[^)]*' | head -1)
if [ -n "$IPAD_TYPE" ]; then UD13=$(sim_for appstore-ipad13 "$IPAD_TYPE" "$RUNTIME_26"); fi
UD65=""
if xcrun simctl list devicetypes | grep -q "iPhone-11-Pro-Max" && [ -n "$RUNTIME_18" ]; then
  UD65=$(sim_for appstore-65 com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max "$RUNTIME_18")
fi

if [ "${1:-}" != "--skip-build" ]; then
  xcodegen generate -s App/project.yml -q
  xcodebuild -project App/LooplApp.xcodeproj -scheme loopl -configuration Debug -sdk iphonesimulator \
    -destination "id=$UD69" -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO -quiet
fi
APP="$DD/Build/Products/Debug-iphonesimulator/loopl.app"

# scene → (launch args after --skip-onboarding, caption). The story mirrors loopl.dev landing-v2; every scene is a DEBUG
# DesignFixture (no model, no network). SD is a folder that stands in for a USB-C drive (`--storage-fixture`).
SD=${SD:-/tmp/loopl}
SCENES=(
  "01-tool|--design-fixture tool|Tools, inline. Tap a row for the details."
  "02-vision|--design-fixture vision|Show it a photo. It sees, then it acts."
  "03-approval|--design-fixture approval|Every request leaves with your approval."
  "04-models|--design-fixture persona --design-local-vision --design-tab models --design-models shelf --design-collection bundled --storage-fixture none --design-mine|What is on your iPhone first. Then where models come from."
  "05-audio|--design-fixture audio|Talk. The model calls transcribe itself."
  "06-train|--design-fixture empty --design-tab models --design-train form|Train your own, on your conversations."
  "07-share|--design-fixture history --design-share review|Your conversations → your private dataset."
  "08-storage|--design-fixture empty --design-tab settings --design-settings storage --storage-fixture $SD|Models on a USB-C drive."
  "09-edit|--design-fixture edit --design-editing|Hold a message to edit it."
  "10-onboarding|--design-fixture onboarding --design-onboarding-step pick --design-apple-fm --no-skip|Your models. Or Apple Intelligence, no download."
)
# per-scene settle time (the audio scene writes a real recording first; storage copies a fake model)
settle() { case "$1" in 05-audio|08-storage) echo 10;; 07-share|09-edit) echo 7;; *) echo 5;; esac; }

shoot() { # udid size
  local ud=$1 size=$2 dir="$PWD/$OUT/$2"
  mkdir -p "$dir"
  xcrun simctl boot "$ud" 2>/dev/null || true
  xcrun simctl bootstatus "$ud" -b >/dev/null
  xcrun simctl status_bar "$ud" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 --operatorName "" >/dev/null 2>&1 || true
  xcrun simctl install "$ud" "$APP"
  xcrun simctl ui "$ud" appearance "${APPEARANCE:-light}" >/dev/null 2>&1 || true
  # the simulator's one-time "slide to type" keyboard tip would sit over the 09-edit keyboard
  xcrun simctl spawn "$ud" defaults write com.apple.Preferences UIKeyboardDidShowContinuousPathIntroduction -bool true >/dev/null 2>&1 || true
  mkdir -p "$SD"
  for s in "${SCENES[@]}"; do
    IFS='|' read -r name args caption <<<"$s"
    xcrun simctl terminate "$ud" technology.tiny.loopl 2>/dev/null || true
    skip=--skip-onboarding; case "$args" in *--no-skip*) skip=""; args=${args//--no-skip/};; esac
    # shellcheck disable=SC2086
    xcrun simctl launch "$ud" technology.tiny.loopl $skip $args >/dev/null
    sleep "$(settle "$name")"
    xcrun simctl io "$ud" screenshot "$dir/$name.png" >/dev/null
    echo "$dir/$name.png  $(magick identify -format '%wx%h' "$dir/$name.png" 2>/dev/null || sips -g pixelWidth -g pixelHeight "$dir/$name.png" | awk '/pixel/ {printf "%s ", $2}')"
  done
  xcrun simctl status_bar "$ud" clear >/dev/null 2>&1 || true
  if [ "${FRAMED:-0}" = 1 ] && command -v magick >/dev/null; then
    mkdir -p "$dir/framed"
    for s in "${SCENES[@]}"; do
      IFS='|' read -r name args caption <<<"$s"
      local w h; w=$(magick identify -format '%w' "$dir/$name.png"); h=$(magick identify -format '%h' "$dir/$name.png")
      # caption band on top (14% of height), shot scaled into the rest, flame gradient canvas
      magick -size "${w}x${h}" gradient:'#0E0E11-#1C120B' \
        \( "$dir/$name.png" -resize "$((w*86/100))x" \) -gravity south -geometry +0+0 -composite \
        -gravity north -font "/System/Library/Fonts/Supplemental/Arial Bold.ttf" -pointsize $((w/22)) -fill '#FBF5E9' -annotate +0+$((h*6/100)) "$caption" \
        "$dir/framed/$name.png"
    done
  fi
}

shoot "$UD69" "6.9"
if [ -n "$UD13" ]; then shoot "$UD13" "ipad13"; fi
if [ -n "$UD65" ]; then shoot "$UD65" "6.5"; else echo "NOTE: no iPhone 11 Pro Max sim available — 6.5\" set must be produced by resizing 6.9\" (1320×2868 → 1284×2778, letterbox) at upload time"; fi
echo "done → $OUT"
