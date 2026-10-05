#!/usr/bin/env bash
# docs/check_snippets.sh — every ```swift block in docs/ tagged `// snippet: compile` must typecheck
# against the CURRENT package. Run from the repo root (CI does it in the docs workflow; locally: ./docs/check_snippets.sh).
#
#   ```swift
#   // snippet: compile            → the block is a whole file (top-level code allowed; imports added if missing)
#   // snippet: compile(wrap)      → the block is wrapped in `func snippet() async throws { … }` (statements only)
#   // snippet: compile(runtimes)  → also imports LooplRuntimes (needs the MLX deps built — `swift build` does it)
#   // snippet: compile(wrap,runtimes)
#   ```
# Untagged blocks are prose (fragments, pseudo-code, Python) and are skipped.
#
# How: `swift build` (products Loopl + LooplRuntimes) → swiftc -typecheck -I .build/<cfg>/Modules
#      plus every SwiftPM-generated clang module map, so `import LooplRuntimes` resolves MLX/Cmlx/yyjson transitively.
set -euo pipefail
cd "$(dirname "$0")/.."

CFG="${SNIPPETS_CONFIG:-debug}"
MODULES=".build/$CFG/Modules"
SKIP_BUILD="${SNIPPETS_SKIP_BUILD:-0}"
if [[ "$SKIP_BUILD" != "1" ]]; then
  # --target (not --product): a library product makes SwiftPM build the whole package, incl. LooplUI (SwiftUI, iOS-first).
  for t in Loopl LooplRuntimes; do
    echo "▸ swift build --target $t …"
    if ! out="$(swift build -c "$CFG" --target "$t" 2>&1)"; then echo "$out" | grep -E "error:" | head -10; echo "✗ swift build --target $t failed"; exit 2; fi
    echo "$out" | grep -E "Build of target|Build complete" || true
  done
fi
[[ -d "$MODULES" ]] || { echo "✗ $MODULES missing — run swift build first"; exit 2; }

CC_FLAGS=()
for m in .build/"$CFG"/*.build/module.modulemap; do [[ -f "$m" ]] && CC_FLAGS+=(-Xcc "-fmodule-map-file=$m"); done
while IFS= read -r d; do CC_FLAGS+=(-Xcc "-I$d"); done < <(find .build/checkouts -path "*/include/module.modulemap" -not -path "*/Tests/*" -not -path "*/Benchmarks/*" 2>/dev/null | xargs -n1 dirname)

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
total=0; failed=0; files=()

# Extract tagged blocks: one file per block, named <page>__<n>.swift, mode in a sidecar.
python3 - "$TMP" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
pat = re.compile(r"```swift[^\n]*\n(.*?)```", re.S)
tag = re.compile(r"^\s*//\s*snippet:\s*compile(?:\(([^)]*)\))?\s*$", re.M)
n_total = 0
for md in sorted(pathlib.Path("docs").rglob("*.md")):
    for i, m in enumerate(pat.finditer(md.read_text(encoding="utf-8")), 1):
        body = m.group(1)
        t = tag.search(body)
        if not t: continue
        modes = {s.strip() for s in (t.group(1) or "").split(",") if s.strip()}
        body = tag.sub("", body, count=1)
        imports = ["import Foundation", "import Loopl"] + (["import LooplRuntimes"] if "runtimes" in modes else [])
        present = set(re.findall(r"^import\s+(\w+)", body, re.M))
        prelude = "\n".join(l for l in imports if l.split()[1] not in present)
        if "wrap" in modes:
            lines = body.rstrip("\n").split("\n")
            # keep the snippet's own imports at file scope
            file_imports = [l for l in lines if l.startswith("import ")]
            rest = [l for l in lines if not l.startswith("import ")]
            src = prelude + "\n" + "\n".join(file_imports) + "\nfunc snippet() async throws {\n" + "\n".join("    " + l for l in rest) + "\n}\n"
        else:
            src = prelude + "\n" + body
        slug = str(md.relative_to("docs")).replace("/", "__").replace(".md", "")
        name = f"{slug}__{i}.swift"
        (out / name).write_text(src, encoding="utf-8")
        (out / (name + ".mode")).write_text(",".join(sorted(modes)))
        n_total += 1
print(n_total)
PY

shopt -s nullglob
for f in "$TMP"/*.swift; do
  total=$((total+1))
  name="$(basename "$f")"
  if out="$(swiftc -typecheck -swift-version 6 -I "$MODULES" "${CC_FLAGS[@]}" "$f" 2>&1)"; then
    echo "✓ $name"
  else
    failed=$((failed+1)); echo "✗ $name"; echo "$out" | grep -E "error:" | head -5 | sed 's/^/    /'
    echo "    --- source ---"; sed 's/^/    /' "$f" | head -40
  fi
done
echo "snippets: $total checked, $failed failed"
[[ $failed -eq 0 ]]
