---
title: "App"
description: "The free loopl iPhone app — the SDK's showcase. Pick a public model and talk to an agent that uses the phone. No account, no analytics."
hide:
  - navigation
---

# The app

Free, no sign-in, no analytics. The first launch fetches a small model; from then on you talk to an agent that uses the phone — with the network off if you like.

[TestFlight — App Store listing pending](https://github.com/cagataycali/loopl/releases){ .md-button .md-button--primary } [Build from source](https://github.com/cagataycali/loopl){ .md-button }

<div class="l-shots" markdown>
<figure markdown>
![Ready — the model is loaded, everything runs on this device](../assets/app/01-hero.png){ loading=lazy }
<figcaption>Ready, on this device.</figcaption>
</figure>
<figure markdown>
![Streaming an answer with Markdown and a Swift code block](../assets/app/02-streaming.png){ loading=lazy }
<figcaption>Streaming, Markdown, code.</figcaption>
</figure>
<figure markdown>
![Two tool calls, expanded to show arguments and results](../assets/app/03-tool.png){ loading=lazy }
<figcaption>Tool rows open to arguments and results.</figcaption>
</figure>
<figure markdown>
![The model list](../assets/app/04-models.png){ loading=lazy }
<figcaption>Any public MLX or GGUF repo.</figcaption>
</figure>
<figure markdown>
![Offline mode](../assets/app/05-offline.png){ loading=lazy }
<figcaption>Offline mode refuses every network call.</figcaption>
</figure>
<figure markdown>
![Settings](../assets/app/06-settings.png){ loading=lazy }
<figcaption>No token, no account, no cap.</figcaption>
</figure>
</div>

| | |
|---|---|
| **Chat** | a document, not bubbles: streaming text, folded thinking, tool rows with timing, image attachments, a mic that records a take for `transcribe`, Stop. |
| **Models** | the catalog plus **Browse Hugging Face** — search, see size, context and whether it fits, download. Apple's model on iOS 26. |
| **Settings** | system prompt, which tools, what asks first, **offline mode**. |
| **History** | finished conversations. Select a few → [Share to Hugging Face](share-to-hugging-face.md): reviewed, redacted, into a private dataset of yours. |

## Tools

Fewer tools make a better agent — every tool is one more thing a small model can pick wrongly, so the app ships only what earns its place, one line each. Settings turns any of them off.

| | |
|---|---|
| `current_time` · `calculator` | any time zone; exact arithmetic |
| `remember` · `recall` | notes the agent keeps between chats, on the device |
| `http` | any HTTPS request — writes ask first |
| `device_info` | battery, storage, model, OS |
| `generate_image` | a picture from a prompt (Image Playground) |
| `generate_voice` | speaks with on-device voices, Personal Voice included |
| `transcribe` | speech to text, offline. Tap the mic in the composer, record, send — the model sees `[audio attached: …]` and decides to call it; nothing is transcribed behind its back |
| `translate` | Apple's offline translation packs |
| `describe_image` | scene labels, faces, barcodes on an attached photo (Vision) |
| `flashlight` · `vibrate` | torch on/off/dimmed; haptic patterns |
| `open_app` | another app via deep link, with context — asks first unless allow-listed |

## Requirements

iOS 18+, 8 GB RAM recommended — the app checks memory and disk before a download. MLX needs a device; GGUF also runs on the simulator. Apple's model needs iOS 26 with Apple Intelligence on.

## Motion

Nothing spins. Text fades in by chunk, tool rows open on a spring, details zoom out of the row you tapped, the mark draws itself once at launch. Under Reduce Motion everything is a plain cross-fade.

## Built on the SDK

The app is `App/` in the repository — `Agent` and `Transcript` from `Loopl`, the three runtimes, the iPhone tools and the `LooplUI` components. Read it as the worked example.
