# Privacy policy

*Effective 2026-10-05 · applies to the loopl iOS app and the loopl SDK.*

**loopl collects no data.** There are no accounts, no analytics, no crash reporting, no advertising
identifiers and no servers operated by us. We cannot see your prompts because they never leave your device.

## What the app does on the network

| Connection | When | What is sent |
|---|---|---|
| `https://huggingface.co` | on first launch (the default Qwen3-0.6B model) and when **you** pick another model | an **anonymous** request for that public repository's files — no token, no account, no identifier |
| nothing else | — | — |

Running a model, chatting, tool calls (`current_time`, `calculator`, `device_info`, `remember`/`recall`)
and reading the catalog happen entirely on the device. The optional `http_get` tool fetches the URL the
model asks for, only while you are online, and shows you the URL in the tool card.

## What stays on the device

There is no account and no token: the app has nothing that could identify you to anyone, including us.

- **Conversations** — stored in the app's Application Support folder, deleted when you delete them or the app.
- **Model weights** — Application Support, excluded from iCloud backup.
- **Notes** written by the `remember` tool — Application Support, never synced.

## Apple Foundation Models

On iOS 26 the app can use Apple's on-device model. That runs under Apple's own on-device privacy model
and guardrails; loopl adds nothing to it and receives nothing from it beyond the generated text.

## Children

loopl does not knowingly collect any information from anyone, including children, because it collects
no information.

## App Store nutrition label

**Data Not Collected.** No data is collected from this app.

## Changes

This page is the policy. Changes are committed to the public repository with a dated changelog entry.
Contact: open an issue at [github.com/cagataycali/loopl](https://github.com/cagataycali/loopl/issues).
