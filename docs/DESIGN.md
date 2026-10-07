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

## Words

Copy in the app is written for someone opening it for the first time: short plain words, one idea per sentence, no developer voice (ids, file names, formats, byte counts). The technical fact is never lost — it moves one tap away (an expanded card, a "Technical" line, the accessibility label). The lane that reads every string with this lens keeps the list below; new copy follows it.

| We say | Not | Where |
|---|---|---|
| model | checkpoint, weights, repo, quant, 4-bit, MLX, GGUF | everywhere a person reads; build names stay in ids and in the expanded card |
| download | pull, fetch | |
| drive | volume, external storage, mount | Storage |
| tool | function, capability | row titles are plain labels (*Time*, *Copy to clipboard* — `ToolLabel`); the id sits in the expanded card |
| conversation | chat, thread, turn, row, shard | History + Train both count conversations |
| sees pictures / text only | vision, VL, multimodal | Models rows |
| memory | RAM, context, ctx, KV | "needs 8 GB of memory"; context size is a Technical fact |
| pass | epoch | Train |
| helper | sub-agent, child agent, use_agent | transcript cards, the wake line |
| tidied its notes | compact, manage_messages | the quiet transcript marker |
| instructions | system prompt (allowed as the Settings field's name) | system_prompt card copy |
| the model | the agent, the loop | user-facing; "loopl" names the app |
| asks you first / waits for your tap | approval, HITL, interrupt | |
| sends data / reads a page | POST/PUT/PATCH/DELETE / GET/HEAD | Network footer; the method pill on the card stays |
| Hugging Face account / token | HF, hub | one reusable sentence: *read* downloads your private models, *write* also shares and trains |
| Technical | advanced, developer | the label that hides jargon |

Dates: relative within a week (*tomorrow at 9:00*, *Fri 9 Oct at 15:00*), the year only beyond — never an ISO stamp. Sizes *1.75 GB* / *652 MB*; durations *1 min 13 s*, *about 16 minutes*.
