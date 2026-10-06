#!/usr/bin/env bash
# docs/check_symbols.sh — type names the docs mention (`Backticked`) vs the public types in Sources/.
# Exit 1 when a documented type does not exist (typos, renames). Names in docs/allowed_symbols.txt are
# external (Apple/stdlib/MLX) and skipped. Run from the repo root.
set -euo pipefail; cd "$(dirname "$0")/.."
grep -rhoE '^\s*(public |open )?(final class|class|struct|enum|protocol|actor|typealias) [A-Z][A-Za-z0-9_]+' Sources | awk '{print $NF}' | sort -u > /tmp/loopl-src-types.txt
grep -rhoE '`[A-Z][A-Za-z0-9_]+`' docs --include='*.md' --exclude=changelog.md | tr -d '`' | sort -u > /tmp/loopl-doc-types.txt
allowed=docs/allowed_symbols.txt; [[ -f $allowed ]] || : > $allowed
missing=$(comm -23 /tmp/loopl-doc-types.txt /tmp/loopl-src-types.txt | grep -vxF -f <(grep -v '^#' $allowed) || true)
undocumented=$(comm -13 /tmp/loopl-doc-types.txt /tmp/loopl-src-types.txt | tr '\n' ' ')
echo "public types not mentioned anywhere in docs/: $undocumented"
if [[ -n "$missing" ]]; then echo "✗ documented but NOT in Sources/ (rename? typo? add to $allowed if external):"; echo "$missing" | tr '\n' ' '; echo; exit 1; fi
echo "✓ every documented type exists in Sources/"
