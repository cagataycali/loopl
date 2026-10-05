---
title: App
description: The free loopl iOS app — the SDK's reference client. Pick a public model, chat with an agent that uses tools, fully offline. No account, no analytics.
---

# The app

Free, no login, no analytics. First launch downloads `Qwen3-0.6B-4bit` (≈335 MB); then you talk to an agent that calls tools, on the phone, with the network off if you like.

<a class="loopl-btn loopl-btn--primary" href="https://github.com/cagataycali/loopl/releases">App Store — listing pending, TestFlight first</a>
<a class="loopl-btn loopl-btn--ghost" href="https://github.com/cagataycali/loopl">Build from source</a>

<div class="loopl-shots" markdown>
<figure markdown>
![Ready — the model is loaded, everything runs on this device](../assets/app/01-hero.png){ loading=lazy }
<figcaption>Ready. Everything on this device.</figcaption>
</figure>
<figure markdown>
![Streaming an answer with Markdown and a Swift code block](../assets/app/02-streaming.png){ loading=lazy }
<figcaption>Streaming, Markdown, code.</figcaption>
</figure>
<figure markdown>
![Two tool calls, expanded to show arguments and results](../assets/app/03-tool.png){ loading=lazy }
<figcaption>Tool rows expand to arguments and results.</figcaption>
</figure>
<figure markdown>
![The model list](../assets/app/04-models.png){ loading=lazy }
<figcaption>Models: Browse Hugging Face for any public MLX or GGUF repo; Apple Intelligence built in on iOS 26.</figcaption>
</figure>
<figure markdown>
![Offline mode](../assets/app/05-offline.png){ loading=lazy }
<figcaption>Offline mode refuses every network call.</figcaption>
</figure>
<figure markdown>
![Settings](../assets/app/06-settings.png){ loading=lazy }
<figcaption>Settings. No token, no account, no iteration cap.</figcaption>
</figure>
</div>

## Screens

| | |
|---|---|
| **Chat** | document-style transcript (no bubbles), streaming text, folded *Thinking…* rows, tool rows with timing, Stop. |
| **Models** | Recommended catalog (21 public models, MLX + GGUF) and **Browse Hugging Face**: search `mlx-community` or GGUF repos, paste a repo id, see size · context · RAM fit, download any public repo. |
| **Settings** | system prompt, tools on/off, **offline mode**, optional performance footer (tok/s, TTFT, context). |

## Requirements

- iOS 18+. Apple Intelligence model: iOS 26 on an eligible device.
- 8 GB RAM recommended; the app checks `minRAMGB` and free disk before a download and warns before loading.
- MLX needs a real device (Metal). GGUF runs on the simulator too, on CPU.

## Where files live

Application Support — models (excluded from iCloud backup), conversations, notes. Delete a model from the Models tab; everything goes with the app.

## Built on the SDK

The app is `App/` in the repository: `Agent` + `Transcript` from `Loopl`, three runtimes from `LooplRuntimes`, and the `LooplUI` components on the [design tokens](../DESIGN.md). Read it as the worked example.
