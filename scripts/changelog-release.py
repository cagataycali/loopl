#!/usr/bin/env python3
"""Fold the changelog fragments into docs/changelog.md and delete them.

During development each pull request writes `docs/changelog.d/<pr>-<slug>.md`
(see that directory's README) and the docs build splices them into the
Unreleased section. This script is the one moment the shared file is edited: at
release, on one branch, with nobody else pushing.

    python3 scripts/changelog-release.py                      # dry run
    python3 scripts/changelog-release.py --version 0.2.0 --write
    python3 scripts/changelog-release.py --write              # keep them Unreleased

With --version the fragments land under `## <version> - <today, UTC>`, directly
above the previous newest version, and the Unreleased heading stays in place and
empty for the next cycle. Without it they are folded into Unreleased itself,
which is what you want when the fragment count gets long mid-cycle.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "docs" / "hooks"))

from changelog_fragments import (  # noqa: E402
    UNRELEASED_RE,
    fragment_paths,
    read_fragments,
)

CHANGELOG = ROOT / "docs" / "changelog.md"
DOCS = ROOT / "docs"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="version heading to create, e.g. 0.2.0")
    parser.add_argument("--date", help="UTC date for the heading (default: today)")
    parser.add_argument("--write", action="store_true", help="actually edit and delete")
    args = parser.parse_args()

    paths = fragment_paths(DOCS)
    if not paths:
        print("no fragments in docs/changelog.d/ - nothing to fold")
        return 0

    fragments = read_fragments(DOCS)
    text = CHANGELOG.read_text(encoding="utf-8")
    match = UNRELEASED_RE.search(text)
    if match is None:
        print("ERROR: docs/changelog.md has no '## Unreleased' heading", file=sys.stderr)
        return 1

    if args.version:
        if re.search(rf"^##\s+{re.escape(args.version)}\b", text, re.MULTILINE):
            print(
                f"ERROR: docs/changelog.md already has a '## {args.version}' heading. "
                "Two sections with one version number is worse than none - pick the next "
                "version, or fold into Unreleased by dropping --version.",
                file=sys.stderr,
            )
            return 1
        date = args.date or _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
        block = f"\n\n## {args.version} - {date}\n\n{fragments}"
        # after the Unreleased heading, which stays empty for the next cycle
        new_text = text[: match.end()] + block + text[match.end() :]
    else:
        new_text = text[: match.end()] + "\n\n" + fragments + text[match.end() :]

    print(f"{len(paths)} fragment(s): " + ", ".join(p.name for p in paths))
    if not args.write:
        print("dry run - pass --write to edit docs/changelog.md and delete them")
        return 0

    CHANGELOG.write_text(new_text, encoding="utf-8")
    for path in paths:
        try:
            subprocess.run(
                ["git", "rm", "-q", str(path.relative_to(ROOT))], cwd=ROOT, check=True
            )
        except (subprocess.CalledProcessError, ValueError):
            path.unlink()
    print(f"folded into docs/changelog.md and removed {len(paths)} fragment(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
