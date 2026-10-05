---
title: Privacy
description: loopl collects no data. No account, no analytics, no servers. The only network call is an anonymous model download from Hugging Face that you start.
---

# Privacy

*Effective 2026-10-05 · the loopl iOS app and SDK.*

**loopl collects no data.** No accounts, no analytics, no crash reporting, no advertising identifiers, no servers of ours. Your prompts never leave the phone, so we cannot see them.

## Network

| Connection | When | What is sent |
|---|---|---|
| `https://huggingface.co` | first launch (default model) and when **you** pick a model | an anonymous request for a public repository's files — no token, no account |
| the URL the model asks for | only if you enable the `http_get` tool and are online | the request itself; the URL is shown in the tool row |
| anything else | never | — |

Inference, chat, tools and the catalog run entirely on the device. **Offline mode** in Settings refuses every network call.

## On the device

- **Conversations** — Application Support; deleted when you delete them or the app.
- **Model weights** — Application Support, excluded from iCloud backup.
- **Notes** from the `remember` tool — Application Support, never synced.

## Apple Foundation Models

On iOS 26 the app can use Apple's on-device model under Apple's own privacy model and guardrails; loopl receives only the generated text.

## App Store label

**Data Not Collected.** loopl does not knowingly collect information from anyone, including children — it collects none.

Changes to this page are committed to the public repository with a dated [changelog](changelog.md) entry. Contact: [open an issue](https://github.com/cagataycali/loopl/issues).
