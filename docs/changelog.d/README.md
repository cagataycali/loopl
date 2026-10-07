# One changelog fragment per pull request

**Do not add your entry to `docs/changelog.md`.** Write a new file here instead:

```
docs/changelog.d/<pr-number>-<short-slug>.md
```

e.g. `docs/changelog.d/202-ipad-history.md`, containing just your bullet(s):

```markdown
- **History reads the same on an iPad** (IMPROVE-9). ...
```

The site splices every fragment into the **Unreleased** section of the Changelog page
when it builds, newest pull-request number first — so the page a reader sees is
unchanged, and your branch touches a file no other branch has.

## Why

`## Unreleased` in `docs/changelog.md` was the single line every branch had to edit.
One lane measured **6 conflicts in 6 pull requests, every one on this file and on
nothing else** — each costing a resolution, a force-push and a full CI re-run, on the
one file in the diff that nobody reads while reviewing. Worse, a resolution done in a
hurry is how a conflict marker reaches a merge commit.

## Rules

- **One file per pull request**, named with its number. Reuse the file if you push again.
- **Bullets only** — no `##` heading of your own; the Unreleased heading is already there.
- Same voice as the rest of the changelog: what a person can now do or no longer suffers,
  the measurement behind it, and the test that pins it.
- ASCII punctuation where it may end up in a TestFlight *What's New* (App Store Connect
  rejects `U+2011`, `·`, `✓`, `⚡` with a 409).

## At release time

`python3 scripts/changelog-release.py --version 0.2.0` folds every fragment into
`docs/changelog.md` under a dated version heading and deletes the fragments, in one
commit, on one branch, with nobody else pushing. That is the only moment anybody edits
the shared file.
