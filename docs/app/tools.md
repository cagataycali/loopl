---
title: "Tools"
description: "What the agent in the app can do: the iPhone's own abilities among them. Writes ask first; open_app has an allowlist; the rarer tools wait in Settings, off by default."
hide:
  - navigation
---

# Tools in the app

Fewer tools make a better agent — every tool is one more thing a small model can pick wrongly — so the model sees a small everyday set, and the rest wait in **Settings**, off until you want them. Every tool's schema was measured on real 0.8B and 2B models before it shipped; a tool this phone can't run (no Image Playground, no translation pack) is hidden from the model rather than offered and failing.

<div class="l-shots l-shots--v2">
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../../assets/app2/tool-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/tool-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/tool-light.webp" type="image/webp"><img src="../../assets/app2/tool-light.png" alt="Two tool rows, Time and Calculator, opened to arguments and results" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Every call is a row: arguments, result, time.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../../assets/app2/approval-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/approval-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/approval-light.webp" type="image/webp"><img src="../../assets/app2/approval-light.png" alt="An approval card for a POST request with Approve, Deny and Edit" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Writes ask first.</figcaption></figure>
<figure class="l-shot"><div class="l-phone l-phone--mini" aria-hidden="true"><div class="l-phone__screen"><picture><source srcset="../../assets/app2/audio-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/audio-dark.png" media="(prefers-color-scheme: dark)"><source srcset="../../assets/app2/audio-light.webp" type="image/webp"><img src="../../assets/app2/audio-light.png" alt="A recorded take in the composer transcribed by the transcribe tool" width="393" height="852" loading="lazy" decoding="async"></picture></div></div><figcaption>Record a take; the model calls transcribe.</figcaption></figure>
</div>

| | |
|---|---|
| `current_time` · `calculator` | any time zone; exact arithmetic |
| `remember` · `recall` | notes the agent keeps between chats, on the device |
| `http` | any HTTPS request — writes ask first; refused in offline mode |
| `device_info` | battery, storage, model, OS |
| `manage_messages` | the model tidies its **own** context in a long chat — `compact` drops old tool calls and results but keeps every message's text, `drop`/`clear` remove old turns, `stats`/`list` show the size. The chat on screen never changes; the transcript gets one quiet line, *"2 turns compacted by the agent · your history is unchanged"*. No approval card — it edits only what the model sees |
| `system_prompt` | the model reads or changes its **own** system prompt when you ask for a standing rule — *"from now on always answer in Turkish"* → `append`; *"what are your instructions?"* → `get`; `set` replaces, `reset` restores the default. Every change stops at an approval card that shows **old → new**; after you approve, it applies from the model's very next step and to every new conversation. Settings › System prompt then reads *changed by the agent · 8:25 PM* with one-tap **Revert** (the last five prompts are kept) |
| `render_ui` | a **native card** instead of prose — bar/line/pie charts (Swift Charts), a map with pins and a route (tap opens Maps), a flow diagram, tables, key/value grids, lists, progress bars, markdown. The model sends a small typed spec; the app draws it — nothing runs, no web view. An unknown component type is named on the card, never dropped. Cards stay in History and re-render from the saved call |
| `ask_user` | the model asks **you** mid-turn with a native card — Yes/No, a radio list, checkboxes, a text field, a row of chips, a small form (text · password · number · toggle), or a note to acknowledge. The agent waits (180 s by default) with a visible *waiting for you* state; **Cancel** is always there and the model is told honestly. Passwords are typed into a secure field and never appear in the chat, History or an export — only the model gets them, once, to use them. [How it works](../sdk/ask-user.md) |
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

## The model can mount a tool itself

`manage_tools` is always on. When the model needs a tool that is switched off — say you asked it to fetch a page while `http` is off — it can call `manage_tools list`, see every tool the app has (and why one cannot run on this device), and `mount` the one it needs. The mount counts **for this conversation** and works on the model's very next step, inside the same answer; a new conversation starts from your switches again. A small model often skips the ceremony and just calls the tool it wants — that works too: calling a known, switched-off tool mounts it for the conversation and runs it, and the result says so. Settings › Tools shows the difference as *mounted for this conversation* / *unmounted for this conversation* and one line under the list says what the agent changed. Your switch always wins: flipping a tool in Settings applies to the current conversation too.

Measured, not assumed: the ManageToolsMeasurement test runs the real loopl 0.8B and 2B models with the needed tool unmounted and records whether the model mounted it and used it in the same turn (numbers in the changelog).

## Asking first

A call that writes — `http` with POST/PUT/DELETE, `open_app`, `clipboard_write` — stops at an **approval card**: the exact request, **Approve**, **Deny**, or **Edit** the arguments. Deny, and the model is told it was denied and carries on without it. **Settings › Network › Ask before** chooses: every request, writes only (the default), or never. An unanswered card is denied after two minutes.

`open_app` asks every time unless you put the app's scheme on its allowlist (**Settings › Tools › open_app › Open without asking**). `shortcuts://` is the useful one: the agent can run a Shortcut with text as input.

## Controls on a result

Some results come with a **live control** right under the tool row — no need to ask the model again:

| Result | Control |
|---|---|
| `flashlight` on | **Turn off** (and *Turn on* once it's off) |
| `vibrate` | **Vibrate again** |
| `music` | a mini player — previous · pause/play · next, and the volume slider |
| `location` | a pin on a small map; tap to open Maps |
| `calendar_create` · `reminders_create` | **Open in Calendar** / **Open in Reminders** |

Tapping one runs **the same tool** with those arguments through the normal path — if the tool asks first, you get the usual approval card — and the row updates with the fresh result (*"flashlight: off"*, the switch now says *Turn on*) plus a quiet *updated by your tap*. It is not a new message: the row keeps its original arguments and no new row appears; History saves the latest state; the model is told *the user tapped this in the app* so its next answer is right. If the tap is denied or fails, the card keeps its last true state and the error line under the chat says why. Controls are drawn disabled while an answer is being generated or when no model is loaded — the state they show is still true. VoiceOver reads the state (*"Turn off, currently on"*).

## When a call fails

The model sees the error, word for word, and tries again with better arguments or answers without the tool. loopl never silently retries or blocks a repeat — what you see in the row is what the model read.

Building your own? The same tools are in the SDK: [Tools](../sdk/tools.md).

<div class="l-actions l-actions--page"><a class="l-btn l-btn--ink l-btn--tf" href="https://testflight.apple.com/join/uUNjfzW9">Get it on TestFlight</a></div>
