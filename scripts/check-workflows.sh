#!/usr/bin/env bash
# Parse every GitHub Actions workflow and refuse a file that is not valid YAML.
#
# Why this exists: a malformed workflow does not fail "a job" — GitHub creates a run with
# ZERO jobs, names it after the FILE PATH (".github/workflows/ci.yml" instead of "ci") and
# marks it failed, with no log to download. It reads exactly like "CI broke on my code".
# The one that bit a plain YAML scalar may not contain a colon-space, so
#
#     run: grep -E "error: -\[|…" log      # ← ": " inside a PLAIN scalar
#
# parsed as a mapping. A block scalar (`run: |`) is always safe for shell lines.
#
# Uses the ruby that ships with macOS and every GitHub runner — no install step.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -e "$f" ] || continue
  if ruby -ryaml -e 'd = YAML.load(File.read(ARGV[0])); abort "no jobs:" if !d.is_a?(Hash) || d["jobs"].nil?' "$f" 2>/tmp/wf.err; then
    echo "ok   $f  (jobs: $(ruby -ryaml -e 'puts YAML.load(File.read(ARGV[0]))["jobs"].keys.join(", ")' "$f"))"
  else
    echo "BAD  $f"; sed 's/^/     /' /tmp/wf.err; fail=1
  fi
done

# --- The app workflows must ignore the same docs-only paths -------------------
#
# `ci` and `ui` both carry a `paths-ignore` so a documentation change does not spend a macOS
# runner. The lists were identical by hand, which lasted until the first new docs-only file:
# #202 added `.github/workflows/docs-pr.yml` and `scripts/changelog-release.py`, neither of
# them in either list, so merging a docs-only PR started a full `ci` AND a two-device `ui`
# run — ~80 minutes of macOS runner time to verify a changelog. Worse than the cost: `ui`
# keeps only ONE pending run per group, so a pointless run can take the slot that the next
# real app change needed, which is the starvation that kept `ui` from going green at all.
#
# So the set lives HERE, once, and both workflows are checked against it. Adding a docs-only
# path means adding it in this list and in both workflows - and forgetting is now a red build
# instead of a silent 80 minutes.
docs_only=(
  'docs/**'
  'mkdocs.yml'
  'requirements-docs.txt'
  '.github/workflows/docs.yml'
  '.github/workflows/docs-pr.yml'
  'scripts/changelog-release.py'
)
for f in .github/workflows/ci.yml .github/workflows/ui.yml; do
  [ -e "$f" ] || continue
  missing=$(DOCS_ONLY="${docs_only[*]}" ruby -ryaml -e '
    d = YAML.load(File.read(ARGV[0]))
    on = d["on"] || d[true] || {}                      # YAML 1.1: a bare `on:` key loads as true
    have = ((on["push"] || {})["paths-ignore"] || [])
    want = ENV["DOCS_ONLY"].split(" ")
    puts (want - have).join(", ")' "$f")
  if [ -n "$missing" ]; then
    echo "BAD  $f  does not ignore docs-only paths: $missing"
    echo "     a documentation change would start this workflow on a macOS runner for nothing"
    fail=1
  else
    echo "ok   $f  ignores all ${#docs_only[@]} docs-only paths"
  fi
done

exit $fail
