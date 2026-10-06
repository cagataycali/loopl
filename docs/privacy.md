---
title: "Privacy"
description: "loopl collects no data. No account, no analytics, no servers. The only network call is a model download you start."
hide:
  - navigation
---

# Privacy

*Effective 2026-10-05 · the loopl app and SDK.*

**loopl collects no data.** No accounts, analytics, crash reporting, advertising identifiers or servers of ours. Your prompts never leave the phone, so we can't see them.

## Network

| Connection | When | What is sent |
|---|---|---|
| `huggingface.co` | when **you** pick a model | an anonymous request for a public repo's files — or, if you pasted a Hugging Face token in Settings, a Bearer request to this host only (Keychain, dropped on the CDN redirect) |
| a URL the agent asks for | only with the `http` tool on, online, and after you approve writes | that request, shown in the tool row |
| anything else | never | — |

Inference, chat and tools run on the device. **Offline mode** refuses every network call.

## On the device

Conversations, model weights (excluded from iCloud backup) and `remember` notes live in Application Support and go when you delete them or the app.

Apple's on-device model, on iOS 26, runs under Apple's own privacy terms; loopl receives only the text.

## App Store label

**Data Not Collected.** Changes to this page are dated in the [changelog](changelog.md). Contact: [open an issue](https://github.com/cagataycali/loopl/issues).
