#!/usr/bin/env bash
# Parse every GitHub Actions workflow and refuse a file that is not valid YAML.
#
# Why this exists: a malformed workflow does not fail "a job" — GitHub creates a run with
# ZERO jobs, names it after the FILE PATH (".github/workflows/ci.yml" instead of "ci") and
# marks it failed, with no log to download. It reads exactly like "CI broke on my code".
# The one that bit IMPROVE-6: a plain YAML scalar may not contain a colon-space, so
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
exit $fail
