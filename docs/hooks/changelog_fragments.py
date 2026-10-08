"""One changelog fragment per pull request, instead of one shared anchor.

Until now every pull request added its bullet directly under `## Unreleased` in
`docs/changelog.md`. That single line is the only thing two concurrent branches
both had to touch, so it conflicted every time: one lane measured **6 conflicts
in 6 pull requests, all on this file and on nothing else**, each costing a
resolution and a CI re-run on a file nobody reads while reviewing.

A pull request now writes `docs/changelog.d/<pr>-<slug>.md` — a file no other
branch has — and this hook splices those fragments into the Unreleased section
while the site builds, newest pull request first. `docs/changelog.md` keeps the
released history and is edited only at release time, by
`scripts/changelog-release.py`.

The fragments are never published as pages of their own: `on_files` drops the
whole directory from the build, so the only place a reader meets them is the
Changelog page.

Self-test (no mkdocs needed, runs in CI):  python3 docs/hooks/changelog_fragments.py --selftest
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

FRAGMENT_DIR = "changelog.d"
CHANGELOG_PAGE = "changelog.md"
UNRELEASED_RE = re.compile(r"^##\s+Unreleased\b.*$", re.MULTILINE)
# <pr>-<slug>.md — the number is what orders the section, the slug is for humans.
NUMBERED_RE = re.compile(r"^(\d+)[-_]")
SKIP_NAMES = {"README.md", "readme.md"}


def fragment_paths(docs_dir: Path) -> list[Path]:
    """Every fragment, newest pull request first; un-numbered ones last, by name."""
    directory = docs_dir / FRAGMENT_DIR
    if not directory.is_dir():
        return []
    files = [
        path
        for path in directory.glob("*.md")
        if path.name not in SKIP_NAMES and not path.name.startswith(".")
    ]

    def sort_key(path: Path):
        match = NUMBERED_RE.match(path.name)
        if match:
            # negative => descending by pull-request number
            return (0, -int(match.group(1)), path.name)
        return (1, 0, path.name)

    return sorted(files, key=sort_key)


def read_fragments(docs_dir: Path) -> str:
    """The fragments as one markdown block, or an empty string when there are none."""
    blocks = []
    for path in fragment_paths(docs_dir):
        text = path.read_text(encoding="utf-8").strip()
        if text:
            blocks.append(text)
    return "\n".join(blocks)


def splice(markdown: str, fragments: str) -> str:
    """Put `fragments` at the top of the Unreleased section of `markdown`.

    Raises when the heading is missing: a silent no-op would mean a release note
    that nobody can see, which is worse than a failed build.
    """
    if not fragments:
        return markdown
    match = UNRELEASED_RE.search(markdown)
    if match is None:
        raise ValueError(
            f"docs/{CHANGELOG_PAGE} has no '## Unreleased' heading, so the "
            f"{len(fragment_paths(Path('docs')))} fragment(s) in docs/{FRAGMENT_DIR}/ "
            "have nowhere to go. Add the heading back, or fold the fragments in with "
            "scripts/changelog-release.py."
        )
    end = match.end()
    return markdown[:end] + "\n\n" + fragments + markdown[end:]


# --- mkdocs hooks ---------------------------------------------------------


def on_files(files, **kwargs):
    """Keep the fragment directory out of the built site."""
    prefix = FRAGMENT_DIR + "/"
    for file in list(files):
        if file.src_uri.startswith(prefix):
            files.remove(file)
    return files


def on_page_markdown(markdown, page=None, config=None, **kwargs):
    if page is None or page.file.src_uri != CHANGELOG_PAGE:
        return None
    docs_dir = Path(config["docs_dir"]) if config else Path("docs")
    return splice(markdown, read_fragments(docs_dir))


# --- self-test ------------------------------------------------------------


def _selftest() -> int:
    import tempfile

    failures = []

    def check(name, got, want):
        if got != want:
            failures.append(f"{name}:\n  got  {got!r}\n  want {want!r}")

    with tempfile.TemporaryDirectory() as tmp:
        docs = Path(tmp)
        (docs / FRAGMENT_DIR).mkdir()
        (docs / FRAGMENT_DIR / "198-freshness.md").write_text("- older PR\n")
        (docs / FRAGMENT_DIR / "201-squeeze.md").write_text("- newer PR\n")
        (docs / FRAGMENT_DIR / "README.md").write_text("how to write a fragment\n")
        (docs / FRAGMENT_DIR / ".DS_Store").write_text("junk\n")
        (docs / FRAGMENT_DIR / "no-number.md").write_text("- un-numbered\n")

        names = [p.name for p in fragment_paths(docs)]
        check("order: newest PR first, README skipped, un-numbered last",
              names, ["201-squeeze.md", "198-freshness.md", "no-number.md"])

        check("fragments joined in that order",
              read_fragments(docs), "- newer PR\n- older PR\n- un-numbered")

        page = "# Changelog\n\nintro\n\n## Unreleased - a title\n\n- already here\n\n## 0.1.0\n"
        spliced = splice(page, read_fragments(docs))
        check("spliced under the heading, above what was already there",
              spliced,
              "# Changelog\n\nintro\n\n## Unreleased - a title\n\n"
              "- newer PR\n- older PR\n- un-numbered\n\n- already here\n\n## 0.1.0\n")
        check("released history untouched", spliced.count("## 0.1.0"), 1)

        check("no fragments: byte-identical page", splice(page, ""), page)

        empty = Path(tmp) / "empty"
        empty.mkdir()
        check("no directory at all: no fragments", read_fragments(empty), "")

        try:
            splice("# Changelog\n\nno heading here\n", "- a bullet")
        except ValueError:
            pass
        else:
            failures.append("a missing '## Unreleased' heading must raise, not pass silently")

    if failures:
        print("changelog_fragments selftest FAILED")
        for failure in failures:
            print(" -", failure)
        return 1
    print("changelog_fragments selftest ok (7 checks)")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    print(read_fragments(Path(sys.argv[1] if len(sys.argv) > 1 else "docs")))
