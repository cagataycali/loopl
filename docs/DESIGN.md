---
title: Design tokens
description: The loopl visual system in one page — paper/ink light, charcoal dark, one flame accent, Inter Tight + system type, an 8-pt scale.
hide:
  - navigation
---

# Design tokens

One system for loopl.dev and the app. Warm **paper & ink** in light, **deep charcoal** in dark, a single **flame** accent. No gradients, no glass, no second accent.

## Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| `--l-bg` | `#F7F3EC` | `#15161A` | page |
| `--l-surface` | `#FFFDF9` | `#1D1F24` | cards, code |
| `--l-ink` | `#1A1714` | `#ECE8E1` | text |
| `--l-ink-2` | `#6B645C` | `#9A948B` | secondary text |
| `--l-line` | `#E6DFD4` | `#2B2E35` | borders, rules |
| `--l-flame` | `#B8420A` | `#FF7A2E` | the one accent as **text**: links, kicker, focus (≥ 4.5:1 on both papers) |
| `--l-flame-fill` | `#FF6A1A` | `#FF7A2E` | the same accent as a **fill**: primary button, caret |
| `--l-flame-ink` | `#1A1714` | `#15161A` | text on a flame fill (6.2:1) |

Accent on ≤ 5 % of any screen. Every text/background pair in this table meets WCAG AA (4.5:1). Links are ink with a flame underline; buttons are flame **or** outlined ink — never both on one row.

## Type

| Role | Face | Size / line | Weight |
|---|---|---|---|
| Display | **Inter Tight** (self-hosted, 45 KB variable) | 56/60 · 40/44 · 28/32 | 700, tracking −0.02em |
| Body | system (`-apple-system, Inter, system-ui`) | 17/26 · 15/22 | 400 / 600 |
| Code | `ui-monospace, SF Mono, Menlo` | 13.5/20 | 400 |

Headings sentence-case. One `h1` per page. Max line length 68 ch.

## Space — 8-pt scale

`--s1 8` · `--s2 16` · `--s3 24` · `--s4 32` · `--s6 48` · `--s8 64` · `--s12 96` px. Section gap `--s12` desktop, `--s8` mobile. Card padding `--s3`. Radius `--r 12` (cards) · `--r-s 8` (buttons, code) · `--r-pill 999`.

## Components

- **Button** 44 px tall, `--r-s`, flame fill or 1 px ink outline; focus ring 2 px flame offset 2 px.
- **Code card** `--l-surface`, 1 px `--l-line`, no window chrome, copy button on hover.
- **Callout** 3 px left rule in flame (note) or ink (strands); no fills.
- **Table** hairlines only, header `--l-ink-2` small caps.
- **Tool row** (transcript) `name · ms · ✓` on one line, mono, expands to args/result.

## Motion

Only opacity/transform, 160–240 ms, `cubic-bezier(.2,.7,.2,1)`. Everything respects `prefers-reduced-motion: reduce` (animations off, final state shown).

Stylesheet: `docs/stylesheets/loopl.v6.css` · Swift mirror: `LooplDesign` tokens in `LooplUI`.
