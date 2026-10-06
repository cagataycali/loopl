---
title: "App"
description: "The free loopl iPhone app — the SDK's showcase. Pick a public model and talk to an agent that uses the phone. No account, no analytics."
hide:
  - navigation
---

# The app

Free, no sign-in, no analytics. On first launch you pick a model (three cards, sizes and what each can do) and it downloads once; from then on you talk to an agent that uses the phone — with the network off if you like.

<div class="l-actions l-actions--page"><a class="l-btn l-btn--ink l-btn--tf" href="https://testflight.apple.com/join/uUNjfzW9">Get it on TestFlight</a><a class="l-link" href="https://github.com/cagataycali/loopl">Build from source</a></div>
<p class="l-micro">Public beta · iOS 18+ · the App Store listing follows the 1.0 review.</p>

<div class="l-shots l-shots--v2">
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../assets/app2/offline-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/offline-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/offline-light.webp" type="image/webp"><img src="../assets/app2/offline-light.png" alt="The chat screen in airplane mode: the model is ready, everything runs on this device" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Ready, offline, on this device.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../assets/app2/tool-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/tool-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/tool-light.webp" type="image/webp"><img src="../assets/app2/tool-light.png" alt="Two tool rows, current_time and calculator, expanded to arguments and results" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Tool rows open to arguments and results.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../assets/app2/approval-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/approval-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/approval-light.webp" type="image/webp"><img src="../assets/app2/approval-light.png" alt="An approval card for a POST request with Approve, Deny and Edit" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Writes ask first. Deny, and the model is told.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../assets/app2/vision-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/vision-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/vision-light.webp" type="image/webp"><img src="../assets/app2/vision-light.png" alt="A photo of shapes described by a vision model, then a calculator call" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Photos go to vision models.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../assets/app2/audio-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/audio-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/audio-light.webp" type="image/webp"><img src="../assets/app2/audio-light.png" alt="A recorded take in the composer transcribed by the transcribe tool" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Record a take; the model calls transcribe.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../assets/app2/models-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/models-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../assets/app2/models-light.webp" type="image/webp"><img src="../assets/app2/models-light.png" alt="The Models tab: Browse Hugging Face, Train your own, Mine, Apple Intelligence, Qwen3 downloading" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Any public repo, your private ones, or Apple's model.</figcaption></figure>
</div>

| | |
|---|---|
| **Chat** | a document, not bubbles: streaming text, folded thinking, tool rows with timing, image attachments, a mic that records a take for `transcribe`, Stop. |
| **Models** | the catalog plus **Browse Hugging Face** — search, see size, context and whether it fits, download; your private repos under **Mine**; Apple's model on iOS 26. → [Models](models.md) |
| **Settings** | system prompt, which tools, what asks first, **offline mode**, [**Storage**](storage.md) — models on the phone or a USB-C drive. |
| **History** | finished conversations. Select a few → [Share to Hugging Face](share-to-hugging-face.md): reviewed, redacted, into a private dataset of yours. |

## Tools

Eleven tools — time, arithmetic, notes, `http`, and the iPhone's own: images, voice, transcription, translation, Vision, flashlight, haptics, other apps. Writes ask first. → [Tools](tools.md)

## Keyboard

With a hardware keyboard — iPad, Mac, or an iPhone in a case with one — **⌘N** starts a new conversation, **⌘Y** shows History (the sidebar on iPad, the sheet on iPhone), **⌘.** or **Esc** stops an answer mid-stream, and **⌘↩** sends. Plain Return still makes a newline in the composer. Hold **⌘** on iPad to see the list.

## Requirements

iOS 18+, 8 GB RAM recommended — the app checks memory and disk before a download. MLX needs a device; GGUF also runs on the simulator. Apple's model needs iOS 26 with Apple Intelligence on.

## Motion

Nothing spins. Text fades in by chunk, tool rows open on a spring, details zoom out of the row you tapped, the mark draws itself once at launch. Under Reduce Motion everything is a plain cross-fade.

## Built on the SDK

The app is `App/` in the repository — `Agent` and `Transcript` from `Loopl`, the three runtimes, the iPhone tools and the `LooplUI` components. Read it as the worked example.
