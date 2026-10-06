---
title: "Tools"
description: "What the agent in the app can do: eleven tools, the iPhone's own abilities among them. Writes ask first; open_app has an allowlist."
hide:
  - navigation
---

# Tools in the app

Fewer tools make a better agent — every tool is one more thing a small model can pick wrongly — so the app ships only what earns its place. **Settings** turns any of them off; a tool this phone can't run (no Image Playground, no translation pack) is hidden from the model rather than offered and failing.

<div class="l-shots l-shots--v2">
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../../assets/app2/tool-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/tool-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/tool-light.webp" type="image/webp"><img src="../../assets/app2/tool-light.png" alt="Two tool rows, current_time and calculator, expanded to arguments and results" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Every call is a row: arguments, result, time.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../../assets/app2/approval-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/approval-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/approval-light.webp" type="image/webp"><img src="../../assets/app2/approval-light.png" alt="An approval card for a POST request with Approve, Deny and Edit" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Writes ask first.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../../assets/app2/audio-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/audio-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/audio-light.webp" type="image/webp"><img src="../../assets/app2/audio-light.png" alt="A recorded take in the composer transcribed by the transcribe tool" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Record a take; the model calls transcribe.</figcaption></figure>
</div>

| | |
|---|---|
| `current_time` · `calculator` | any time zone; exact arithmetic |
| `remember` · `recall` | notes the agent keeps between chats, on the device |
| `http` | any HTTPS request — writes ask first; refused in offline mode |
| `device_info` | battery, storage, model, OS |
| `generate_image` | a picture from a prompt (Image Playground) |
| `generate_voice` | speaks with on-device voices, Personal Voice included |
| `transcribe` | speech to text, offline — tap the mic, record, send; the model sees `[audio attached: …]` and decides to call it |
| `translate` | Apple's offline translation packs |
| `describe_image` | scene labels, faces, barcodes on an attached photo (Vision) |
| `flashlight` · `vibrate` | torch on/off/dimmed; haptic patterns |
| `open_app` | another app via deep link, with context in the query string |

## Asking first

A call that writes — `http` with POST/PUT/DELETE, `open_app` — stops at an **approval card**: the exact request, **Approve**, **Deny**, or **Edit** the arguments. Deny, and the model is told it was denied and carries on without it. **Settings › Network › Ask before** chooses: every request, writes only (the default), or never. An unanswered card is denied after two minutes.

`open_app` asks every time unless you put the app's scheme on its allowlist (**Settings › On-device Apple tools › open_app › Open without asking**). `shortcuts://` is the useful one: the agent can run a Shortcut with text as input.

## When a call fails

The model sees the error, word for word, and tries again with better arguments or answers without the tool. loopl never silently retries or blocks a repeat — what you see in the row is what the model read.

Building your own? The same tools are in the SDK: [Tools](../sdk/tools.md).

<div class="l-actions l-actions--page"><a class="l-btn l-btn--ink l-btn--tf" href="https://testflight.apple.com/join/uUNjfzW9">Get it on TestFlight</a></div>
