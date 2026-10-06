---
title: "Models"
description: "Pick a model in the app: the curated catalog, any public Hugging Face repo, your private ones under Mine, or Apple's model. Vision is read from the files."
hide:
  - navigation
---

# Models in the app

One tab, four sources. Every row says its size, its context, whether it sees pictures and whether it fits this phone — before anything downloads.

<div class="l-shots l-shots--v2">
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../../assets/app2/models-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/models-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/models-light.webp" type="image/webp"><img src="../../assets/app2/models-light.png" alt="The Models tab: Browse Hugging Face, Train your own, Mine, Apple Intelligence, Qwen3 downloading" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Catalog, Hugging Face, Mine, Apple's model.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../../assets/app2/vision-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/vision-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/vision-light.webp" type="image/webp"><img src="../../assets/app2/vision-light.png" alt="A photo of shapes described by a vision model, then a calculator call" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>A vision model gets the photo button.</figcaption></figure>
</div>

## First launch

Three cards — **Qwen3 0.6B** (fastest), **Qwen3.5 0.8B** (small, sees pictures), **Qwen3.5 2B** (smartest of the three, about 3 GB of memory). The line under them says what the download costs on the network you are on (Wi‑Fi, cellular, offline). On iOS 26 with Apple Intelligence on, *Use Apple Intelligence instead* skips the download. Skippable; the download carries on in the background.

## The catalog

The models loopl is tested with — Qwen3, Qwen3.5, Qwen3‑VL, Llama 3.2, Gemma 3, Phi‑4 mini, SmolLM, as MLX 4‑bit and GGUF — listed with sizes on [Models](../models.md). The app checks memory and free space (on the phone or the [drive](storage.md) you download to) and says why when a model won't fit.

## Browse Hugging Face

Search any public repo. A result becomes a model when loopl can run it: MLX safetensors or a `.gguf`. The sheet shows the files it will fetch, the size, the context it will use on this phone, and a **vision** badge when the repo really carries a vision tower.

## Your private models — Mine

Paste a Hugging Face token in **Settings › Hugging Face** (read is enough to download; write to share and train). **Models › Mine** then lists your own repos, private ones included, newest first — models you [trained from the app](train.md) land here. The token stays in the Keychain and goes only to huggingface.co.

## loopl v1

`loopl-0.8b`, `loopl-2b` and `loopl-4b` — Qwen3.5 post-trained on loopl's own tools and docs — are in the catalog as MLX 4‑bit (with vision) and GGUF (text). They are **gated**: the row asks you to sign in, and downloads with your token once you have access. Their identity is in the weights — the app sends only your own system prompt, to every model.

## Vision, honestly

The photo button follows the weights on the phone, not the model's name: after a download loopl reads the model's own `config.json`, so a text-only export never shows a camera, and a vision export always does.

## When a download won't start

It says why, where you tapped: not enough space (need vs free, with *Open Settings › Storage*), the chosen drive is away, the repo needs a token, or you are offline. Failed rows keep a **Retry**. A model whose tokenizer files are out of date is fixed on first load — *Fixing model files* — without downloading the weights again.

<div class="l-actions l-actions--page"><a class="l-btn l-btn--ink l-btn--tf" href="https://testflight.apple.com/join/uUNjfzW9">Get it on TestFlight</a></div>
