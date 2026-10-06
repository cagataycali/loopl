---
title: "Models"
description: "Pick a model in the app: the curated catalog, any public Hugging Face repo, your private ones under Mine, or Apple's model. Vision is read from the files."
hide:
  - navigation
---

# Models in the app

One tab, read top to bottom in the order a first-time user needs it: **On this iPhone** (what is here, the one in use marked), **Browse Hugging Face**, **Train your own**, **loopl models**, **Mine**. Five sections, never the same model twice. Every row says its size, its context, whether it sees pictures and whether it fits this phone — before anything downloads.

<div class="l-shots l-shots--v2">
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../../assets/app2/models-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/models-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/models-light.webp" type="image/webp"><img src="../../assets/app2/models-light.png" alt="The Models tab: On this iPhone with loopl 2B in use and a download in flight, then Browse Hugging Face, Train your own, loopl models, Mine" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>On this iPhone first; the rest in the order you need it.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../../assets/app2/vision-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/vision-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/vision-light.webp" type="image/webp"><img src="../../assets/app2/vision-light.png" alt="A photo of shapes described by a vision model, then a calculator call" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>A vision model gets the photo button.</figcaption></figure>
</div>

## On this iPhone

The first section is what is on the phone: downloaded models (Apple Intelligence too, when the device has it), the model in use marked with the bolt, a download in flight with its ring and progress, a model on a [drive](storage.md) with its drive's name under it. Swipe left to delete. One glyph per row says its state — in use, on this device, downloading, tap to download. Nothing downloaded yet is a calm shelf, not an error: one line says where models come from.

## Browse Hugging Face · Train your own

Two rows, where you reach for them: search any public repo (yours too, private included, once signed in), and post-tune a model on your own conversations — see [Train your own](train.md).

## The loopl collection

The fourth section of the tab is the [loopl collection on Hugging Face](https://huggingface.co/collections/cagataydev/loopl-on-device-agents-swift-6ac51395b13a9c41d4932eaf), in the curator's order: the MLX 4‑bit builds (with the **vision** badge read from their files), the GGUF builds under one disclosure, each with the collection's note as its subtitle — quiz score against the base model, tool-call results. Tap a row for the same sheet Browse uses, download once, chat. The list refreshes from the Hub once per launch and on pull; offline it shows the last copy (the footer says when it was updated), and a fresh install offline still lists the models from a snapshot shipped with the app. Datasets, bf16 merges and LoRA adapters in the collection are not runnable on the phone and are not shown.

## First launch

The mark draws itself, then three short pages show what you are about to get — an answer with the network off, an approval card you tap yourself, a photo and a recording turning into tool calls. They are the app's real components, not pictures; swipe or tap *Continue*, or *Skip* at any point.

Then the loopl models — **loopl 0.8B** (smallest: quick answers and tools, sees pictures), **loopl 2B** (*Recommended · fast + smart*, preselected: the best balance of speed and quality on an iPhone), **loopl 4B** (most capable; it wants a Pro‑class iPhone with 8 GB — on a 6 GB phone the card says *tight* or *too big* and why). Each card shows its size and a **vision** pill. The line under them says what the download costs on the network you are on (Wi‑Fi, cellular, offline). Below the three sits a full card for **Apple Intelligence** — already on the phone, no download, private, instant, works offline, text only with a 4k context — when the device has it (iOS 26, Apple Intelligence on); otherwise the card says in one line why not. If a pick is a private repo and you are not signed in, the flow asks for the free Hugging Face account right there (or offers Apple Intelligence instead) rather than failing on the first byte; the public loopl models never ask. While the first model downloads you can sign in to Hugging Face (optional — it unlocks your private models and *Train your own*) or tap *Later*. The download carries on in the background if you leave. *Settings › About › Show intro again* replays the whole thing.

## More models

The rest of the catalog — the models loopl is tested with: Qwen3, Qwen3.5, Qwen3‑VL, Llama 3.2, Gemma 3, Phi‑4 mini, SmolLM, DeepSeek, listed with sizes on [Models](../models.md) — sits behind one **More models** row at the end of the loopl models section, so the catalog's depth never outranks them. GGUF (llama.cpp, text only) builds are off the list until **Settings › Look & feel › Show GGUF builds**; anything already downloaded always stays under *On this iPhone*. The app checks memory and free space (on the phone or the [drive](storage.md) you download to) and says why when a model won't fit.

The last block is **Storage** — how much space there is, not only what loopl uses: *On this iPhone* with bytes used and bytes free, one row per [drive](storage.md) you have added (used · free, or *Not connected*), the memory a model can take right now, and a row into **Settings › Storage** to move models or add a USB‑C drive. The footer carries the catalog version.

## Browsing, in detail

A Browse result becomes a model when loopl can run it: MLX safetensors or a `.gguf`. The sheet shows the files it will fetch, the size, the context it will use on this phone, and a **vision** badge when the repo really carries a vision tower. A repo you added but have not downloaded yet waits under the Browse row.

## Your private models — Mine

The last section. Paste a Hugging Face token in **Settings › Hugging Face** (read is enough to download; write to share and train). **Models › Mine** then lists your own repos, private ones included, newest first — models you [trained from the app](train.md) land here. The token stays in the Keychain and goes only to huggingface.co.

## loopl v1

`loopl-0.8b`, `loopl-2b` and `loopl-4b` — Qwen3.5 post-trained on loopl's own tools and docs — are in the catalog as MLX 4‑bit (with vision) and GGUF (text). They are **gated**: the row asks you to sign in, and downloads with your token once you have access. Their identity is in the weights — the app sends only your own system prompt, to every model.

## Vision, honestly

The photo button follows the weights on the phone, not the model's name: after a download loopl reads the model's own `config.json`, so a text-only export never shows a camera, and a vision export always does.

## When a download won't start

It says why, where you tapped: not enough space (need vs free, with *Open Settings › Storage*), the chosen drive is away, the repo needs a token, or you are offline. Failed rows keep a **Retry**. A model whose tokenizer files are out of date is fixed on first load — *Fixing model files* — without downloading the weights again.

<div class="l-actions l-actions--page"><a class="l-btn l-btn--ink l-btn--tf" href="https://testflight.apple.com/join/uUNjfzW9">Get it on TestFlight</a></div>
