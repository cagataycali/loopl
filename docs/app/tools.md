---
title: "Tools"
description: "What the agent in the app can do: the iPhone's own abilities among them. Writes ask first; open_app has an allowlist; the rarer tools wait in Settings, off by default."
hide:
  - navigation
---

# Tools in the app

Fewer tools make a better agent — every tool is one more thing a small model can pick wrongly — so the model sees a small everyday set, and the rest wait in **Settings**, off until you want them. Every tool's schema was measured on real 0.8B and 2B models before it shipped; a tool this phone can't run (no Image Playground, no translation pack) is hidden from the model rather than offered and failing.

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
| `music` | play, pause, next, previous, volume and *what's playing* for the system music player (Apple Music or whatever holds it) — one tool, no approval card; the volume goes through iOS's own slider, so the system volume HUD appears |
| `clipboard_read` · `clipboard_write` | what you copied — text, a link, or a picture the model can `describe_image` — and, after asking, text copied back. Two tools, not one with an `action`: measured on a 0.8B, "what did I copy?" turned into a write 4 times in 6 with the single tool |

## Off by default

Tools you need now and then stay **off** until you switch them on in **Settings › Tools** — every extra tool is one more thing a small model can pick wrongly, and the measured difference is real. Each one asks for its iOS permission the first time it runs, not at install.

| | |
|---|---|
| `calendar_events` · `calendar_create` | what is on your calendar for the coming days; adding an event asks first (EventKit) |
| `reminders_due` · `reminders_create` | open reminders due today or soon; adding one asks first |
| `location` | your city and coordinates rounded to about 1 km, plus the time zone — **Exact position** is a switch in Settings, never something the model can ask for (measured: a 0.8B asked for it every single time); `purpose: weather` hands the model the forecast URL for `http` |
| `contacts_search` | a name → phone numbers and emails, read-only; the model chains it into `open_app` with `tel:` / `sms:` / `mailto:` |
| `photos_recent` | your newest photos, or one day's, handed to the model as pictures — *Selected Photos* access is enough, so you decide which pictures loopl may ever see |

Reads and creates are separate tools on purpose: with one tool carrying both verbs a 0.8B model turned "what did I copy?" into a write 4 times in 6. The create tools' descriptions carry today's date, so "tomorrow at 12:30" becomes a real timestamp without a second tool call.

## Asking first

A call that writes — `http` with POST/PUT/DELETE, `open_app`, `clipboard_write` — stops at an **approval card**: the exact request, **Approve**, **Deny**, or **Edit** the arguments. Deny, and the model is told it was denied and carries on without it. **Settings › Network › Ask before** chooses: every request, writes only (the default), or never. An unanswered card is denied after two minutes.

`open_app` asks every time unless you put the app's scheme on its allowlist (**Settings › Tools › open_app › Open without asking**). `shortcuts://` is the useful one: the agent can run a Shortcut with text as input.

## When a call fails

The model sees the error, word for word, and tries again with better arguments or answers without the tool. loopl never silently retries or blocks a repeat — what you see in the row is what the model read.

Building your own? The same tools are in the SDK: [Tools](../sdk/tools.md).

<div class="l-actions l-actions--page"><a class="l-btn l-btn--ink l-btn--tf" href="https://testflight.apple.com/join/uUNjfzW9">Get it on TestFlight</a></div>
