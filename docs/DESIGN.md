---
title: "Design"
description: "The loopl.dev visual system on one page: one typeface, ink on paper, one flame accent, hairlines, spring motion."
hide:
  - navigation
---

# Design

Absolute minimalism. One typeface, ink on paper, one accent, hairlines instead of boxes. Stylesheet: `docs/stylesheets/loopl.v8.css` (bump the suffix on every change — Cloudflare caches assets 4 h). Swift mirror: `LooplDesign` in `LooplUI`.

## Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| `--l-bg` | `#FBFBFA` | `#0A0A0B` | page |
| `--l-raise` | `#FFFFFF` | `#121214` | code, stage, hover |
| `--l-ink` | `#0B0B0C` | `#EDEDEF` | text, primary button |
| `--l-ink-2` | `#5D5D63` | `#929298` | secondary text |
| `--l-ink-3` | `#9A9A9F` | `#5E5E64` | labels, hints |
| `--l-line` | `#E8E8E5` | `#1F1F23` | every rule and border, 1 px |
| `--l-flame` | `#C2410C` | `#FF7A3D` | the accent as text (≥ 4.5:1) |
| `--l-fill` | `#FF5A1F` | `#FF6A2B` | the accent as a dot, caret, spark |

The accent appears a handful of times per screen: the headline's full stop, the eyebrow dot, a tool's check, the loop's spark. Primary buttons are ink, not flame.

## Type

**Inter Tight** for everything (variable 100–900, self-hosted, 45 KB, no Google Fonts); `ui-monospace` for code.

| Role | Size | Weight · tracking |
|---|---|---|
| Hero | clamp(2.5rem → 5.4rem) | 600 · −0.045em · line-height .98 |
| Section | clamp(1.6rem → 2.6rem) | 600 · −0.045em |
| Page h1 | 1.9rem | 600 · −0.035em |
| Body | 16 px / 1.7 | 400, measure 64ch |
| Label | 11–12 px | 500, `--l-ink-3` |

## Space & shape

Sections breathe: clamp(4rem → 8rem) between them. Radius 10 px for code, 18 px for the stage, pills for buttons. No shadows, no gradients, no glass — except the header's translucent blur.

## Motion

One curve, `cubic-bezier(.22, 1, .36, 1)` (spring-like out). Reveal on scroll 0.9 s, rise 14 px. The landing replays a real-shaped turn: the question, two concurrent tool calls resolving, the answer streaming in word chunks. The loop ring's spark runs 3.6 s per lap. Instant navigation fades the page in. `prefers-reduced-motion: reduce` shows every final state and stops the spark.
