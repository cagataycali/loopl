#!/usr/bin/env bash
# Fetch the official llama.cpp xcframework (ggml-org release asset) into Vendor/llama.xcframework
# so `Package.swift`'s path-based binaryTarget resolves and `GGUFModel` compiles (`#if canImport(llama)`).
#
#   scripts/fetch-llama-xcframework.sh            # device + macOS slices from the release zip (fast, ~62 MB)
#   scripts/fetch-llama-xcframework.sh --with-sim # + build the iOS-Simulator slice from the same tag (cmake, ~10-20 min)
#
# Why not a URL binaryTarget: the official zip ships ios-arm64 (device) + macos only — no iOS Simulator slice —
# so SwiftPM would fail every simulator build at link time. We vendor the zip's slices and, when asked, add a
# simulator slice built with upstream's own build-xcframework.sh. Vendor/ is gitignored.
set -euo pipefail

TAG="${LLAMA_TAG:-b11401}"
SHA256_EXPECTED="${LLAMA_SHA256:-425f871da9d8a3625afba4e46fe55c0278ef6a314744f3840b00b8d1f6e0f165}"   # llama-b11401-xcframework.zip
URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-xcframework.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
WORK="${LLAMA_WORK:-$VENDOR/.llama-$TAG}"
ZIP="$WORK/llama-$TAG-xcframework.zip"
OUT="$VENDOR/llama.xcframework"
WITH_SIM=0
for a in "$@"; do case "$a" in --with-sim) WITH_SIM=1 ;; *) echo "unknown arg $a" >&2; exit 2 ;; esac; done

mkdir -p "$WORK"
if [[ ! -f "$ZIP" ]]; then
  echo "↓ $URL"
  curl -fL --progress-bar -o "$ZIP.part" "$URL" && mv "$ZIP.part" "$ZIP"
fi
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "sha256 $SHA  llama-$TAG-xcframework.zip"
if [[ -n "$SHA256_EXPECTED" && "$SHA" != "$SHA256_EXPECTED" ]]; then
  echo "✗ checksum mismatch (expected $SHA256_EXPECTED). Set LLAMA_SHA256= to accept a new tag." >&2; exit 1
fi

rm -rf "$WORK/unzipped" && mkdir -p "$WORK/unzipped"
unzip -q -o "$ZIP" -d "$WORK/unzipped"
SRC_XC="$(find "$WORK/unzipped" -maxdepth 3 -name 'llama.xcframework' -type d | head -1)"
[[ -d "$SRC_XC" ]] || { echo "✗ no llama.xcframework inside the zip" >&2; exit 1; }

FRAMEWORKS=()
for slice in "$SRC_XC"/*/; do
  fw="$slice/llama.framework"; [[ -d "$fw" ]] && FRAMEWORKS+=("$fw")
done

if [[ "$WITH_SIM" == 1 ]]; then
  SIM_FW="$WORK/src/build-apple/llama.xcframework/ios-arm64_x86_64-simulator/llama.framework"
  if [[ ! -d "$SIM_FW" ]]; then
    command -v cmake >/dev/null || { echo "✗ cmake needed for --with-sim (brew install cmake)" >&2; exit 1; }
    [[ -d "$WORK/src" ]] || git clone -q --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$WORK/src"
    echo "⚙ building the iOS Simulator slice from tag $TAG (upstream build-xcframework.sh ios-sim)…"
    ( cd "$WORK/src" && MAX_PARALLEL_BUILDS=1 ./build-xcframework.sh ios-sim )
    SIM_FW="$(find "$WORK/src/build-apple/llama.xcframework" -maxdepth 2 -path '*simulator*' -name 'llama.framework' | head -1)"
  fi
  [[ -d "$SIM_FW" ]] || { echo "✗ simulator slice not produced" >&2; exit 1; }
  FRAMEWORKS+=("$SIM_FW")
fi

ARGS=()
for fw in "${FRAMEWORKS[@]}"; do ARGS+=(-framework "$fw"); done
rm -rf "$OUT"
xcrun xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT" >/dev/null
echo "✓ $OUT"
# SwiftPM caches the evaluated manifest by content; Package.swift decides on Vendor/ at evaluation time,
# so the cache must go or `canImport(llama)` stays stale until Package.swift changes.
rm -f "$ROOT/.build/manifest.db"* "$HOME/Library/Caches/org.swift.swiftpm/manifests/manifest.db"* 2>/dev/null || true
rm -rf "$ROOT/App/LooplApp.xcodeproj/project.xcworkspace/xcuserdata" 2>/dev/null || true
plutil -extract AvailableLibraries json -o - "$OUT/Info.plist" | python3 -c 'import json,sys; [print("  slice:", l["LibraryIdentifier"]) for l in json.load(sys.stdin)]'
echo "swift package compute-checksum: $(cd "$ROOT" && swift package compute-checksum "$ZIP" 2>/dev/null || echo n/a)"
