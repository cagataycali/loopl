# Changelog

All notable changes to the SDK, the app and this site. Dates are UTC.

## Unreleased

### Added
- **SDK** — `Loopl` core: `Agent`, `Model`, `Tool`/`ToolSpec`/`JSONSchema`, `Message`/`ContentBlock`,
  `AgentEvent`, `Budget` (default unlimited), `LoopDetector` (warns, never stops), `ChatTemplate` +
  `ToolCallParser` for Hermes/Qwen, Llama 3.x, Gemma and bare-JSON dialects, `FakeModel`.
- **Runtimes** — `MLXModel` (mlx-swift-lm 3.32.3, Application Support cache, resume, memory guard,
  rotating KV cache), `AppleFoundationModel` (iOS 26, native `Tool` bridging, snapshot→delta streaming,
  session rollover near the 4,096-token window), `GGUFModel` stub.
- **UI** — `LooplUI`: `AgentTranscriptView`, `StreamingTextView`, `ToolCallCard`, `TokenMeter`,
  `ModelPickerRow`, `DownloadProgressRow`, each with previews.
- **App** — Chat · Models · Agent · Settings tabs; 15-model catalog (`models.json`); HF token in Keychain;
  offline simulation; Increased Memory Limit entitlement; PrivacyInfo "Data Not Collected".
- **Docs** — this site at [loopl.dev](https://loopl.dev), generated models table (`docs/gen_models.py`),
  privacy policy.

### Roadmap
- `GGUFModel` on the llama.cpp xcframework (b11401+) with a C shim for `common/chat`.
- Sliding-window `ConversationManager`.
- Mutating hooks (`beforeToolCall`, `afterToolCall`).
- Parallel tool execution as an opt-in `Agent.Options`.
- Background `URLSession` downloads.
- TestFlight → App Store listing (free).

## 0.1.0 — 2026-10-05

Initial public repository.
