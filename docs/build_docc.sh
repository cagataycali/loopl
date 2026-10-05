#!/usr/bin/env bash
# docs/build_docc.sh [out-dir] — DocC API reference for Loopl + LooplRuntimes as static HTML under <out>/api/.
# No swift-docc-plugin needed: `swift build -emit-symbol-graph` + `xcrun docc convert` (Xcode 16+/26).
#   https://loopl.dev/api/loopl/documentation/loopl/            ← Loopl (core)
#   https://loopl.dev/api/looplruntimes/documentation/looplruntimes/  ← LooplRuntimes
# Env: SNIPPETS_SCRATCH (reuse a warm .build), SNIPPETS_CONFIG (debug).
set -euo pipefail; cd "$(dirname "$0")/.."
OUT="${1:-site}"; CFG="${SNIPPETS_CONFIG:-debug}"; SCRATCH="${SNIPPETS_SCRATCH:-.build}"
VERSION="$(grep -m1 -oE '^## [0-9]+\.[0-9]+\.[0-9]+' docs/changelog.md | awk '{print $2}')"; VERSION="${VERSION:-0.0.0}"
SG="$(mktemp -d)"; trap 'rm -rf "$SG"' EXIT
for t in Loopl LooplRuntimes; do
  echo "▸ symbol graph: $t"
  mkdir -p "$SG/$t"
  if ! out="$(swift build -c "$CFG" --scratch-path "$SCRATCH" --target "$t" \
        -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc "$SG/$t.all" 2>&1)"; then
    echo "$out" | grep -E ':[0-9]+:[0-9]+: error:' | head -10; echo "✗ swift build --target $t failed"; exit 2
  fi
  cp "$SG/$t.all/$t"*.symbols.json "$SG/$t/"           # only this module's graphs (deps emit theirs too)
  lower="$(echo "$t" | tr '[:upper:]' '[:lower:]')"
  rm -rf "$OUT/api/$lower"; mkdir -p "$OUT/api"
  xcrun docc convert --fallback-display-name "$t" --fallback-bundle-identifier "dev.loopl.$t" --fallback-bundle-version "$VERSION" \
    --additional-symbol-graph-dir "$SG/$t" --output-path "$OUT/api/$lower" \
    --transform-for-static-hosting --hosting-base-path "api/$lower" >/dev/null
  echo "  → $OUT/api/$lower/documentation/$lower/ ($(ls "$OUT/api/$lower/documentation/$lower" | wc -l | tr -d ' ') symbols)"
done
# /api/ → the core reference
cat > "$OUT/api/index.html" <<HTML
<!doctype html><meta charset="utf-8"><title>loopl API reference</title>
<meta http-equiv="refresh" content="0; url=/api/loopl/documentation/loopl/">
<p>Redirecting to the <a href="/api/loopl/documentation/loopl/">Loopl API reference</a> · <a href="/api/looplruntimes/documentation/looplruntimes/">LooplRuntimes</a></p>
HTML
echo "✓ DocC in $OUT/api (v$VERSION)"
