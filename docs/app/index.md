# The loopl app

A free iOS app that runs the SDK end to end: download a model from Hugging Face, hand the agent a few
tools, chat offline. **No account. No login. No analytics.** It is the reference client for the SDK and
the easiest way to feel what on-device agents are like.

<div class="loopl-hero__cta" markdown>
<a class="loopl-badge" href="https://github.com/cagataycali/loopl/releases" title="App Store listing — coming soon (TestFlight first)">
<span>:fontawesome-brands-apple:</span><span><small>Free · coming soon on the</small><b>App Store</b></span>
</a>
[Build it yourself](../getting-started/run-on-device.md){ .loopl-btn .loopl-btn--ghost }
</div>

!!! info "Availability"
    The App Store link is a placeholder until the listing is approved; TestFlight comes first. Until then
    the app builds from the repo in one `xcodebuild` (see *Run on a device*). This page is updated the
    moment the store URL exists.

## Screens

| Tab | What it does |
|---|---|
| **Chat** | Streaming bubbles · tok/s, TTFT and a context meter (used / max) · **Stop** · tool-call cards that expand to show arguments and result · warnings from the loop detector |
| **Models** | The catalog (runtime, repo, size, context, min RAM) · Download with progress + resume · Delete · *Loaded* indicator · memory headroom warning before a big download |
| **Agent** | Toggle each built-in tool · system prompt · optional `Budget` (iterations / tool calls / time / tokens — all off by default) · context length |
| **Settings** | Hugging Face token (Keychain) · runtime preference (with the availability reason) · offline mode · Demo (scripted) model · clear cache · privacy & about |

## Identity

| | |
|---|---|
| Bundle ID | `technology.tiny.loopl` |
| Price | Free · no in-app purchases |
| Account | none · no sign-in anywhere |
| Distribution | TestFlight first, then the App Store (the badge above lights up when the listing exists) |
| Support | [loopl.dev](https://loopl.dev) · [GitHub issues](https://github.com/cagataycali/loopl/issues) |
| Privacy | [loopl.dev/privacy](../privacy.md) — Data Not Collected |

## Requirements

- iOS 18.0+. For Apple Foundation Models: iOS 26 on an Apple-Intelligence device with it enabled.
- ≥ 6 GB RAM for the small models, 8 GB recommended. The app refuses to download a model the device
  cannot load.
- Network only for the first download of each model. [Offline mode →](offline.md)

## Design

Flame-orange accent, SF Symbols, Dynamic Type, VoiceOver labels on every control, iPad layout.
The components are the same `LooplUI` ones you can use in your own app: `AgentTranscriptView`, `ToolCallCard`,
`TokenMeter`, `ModelPickerRow`, `DownloadProgressRow`, on the `LooplDesign` tokens.
