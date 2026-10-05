# Changelog

All notable changes to the SDK, the app and this site. Dates are UTC.

## Unreleased

### Added
- **SDK** — `Loopl` core: `Agent` actor, `AgentConfig`/`Budget` (default unlimited) + `LoopDetector` (warns, never stops),
  `Model` protocol (actors), `Tool` protocol + `ToolSchema` + `ClosureTool`, `Message`/`ToolCall`/`ToolResult`,
  `ToolCallParser` for Hermes/Qwen, Llama 3 and generic-JSON dialects (repairs truncated calls), `PromptBuilder`,
  `ModelSpec`/`Catalog`, resumable offline-aware `HFDownloader`, `NetworkPolicy`, built-in tools
  (`CurrentTimeTool`, `CalculatorTool`, `RememberTool`, `RecallTool`, `HttpGetTool`), `FakeModel`.
- **Runtimes** — `MLXModel` (mlx-swift-lm 3.32.3, Metal, KV cap from `contextLength`, chat-template tools,
  `enable_thinking` kwargs), `AppleFoundationModel` (iOS 26, availability reasons, manual tool prompting, snapshot→delta
  streaming, estimated token counts), `GGUFModel` stub.
- **UI** — `LooplUI`: `AgentTranscriptView`, `StreamingTextView`, `UserBubble`, `ToolCallCard`, `TokenMeter`, `ModelPickerRow`,
  `DownloadProgressRow` + design tokens (`LooplDesign`, `LooplCard`, `Pill`); `Transcript` reducer in the core.
- **App** — Chat · Models · Agent · Settings tabs; 15-model catalog (`models.json`); download with resume; HF token in
  Keychain; offline mode; Demo (scripted) switch; Increased Memory Limit entitlement; `scripts/build-on-device.sh`.
- **Docs** — this site at [loopl.dev](https://loopl.dev), generated models table (`docs/gen_models.py`), privacy policy.

### Roadmap
- `GGUFModel` on the llama.cpp xcframework (b11401+) with a C shim for `common/chat`.
- Apple Foundation Models native `Tool` bridging.
- Sliding-window conversation manager (today: mutate `agent.messages`).
- Background `URLSession` downloads.
- TestFlight → App Store listing (free).

## 0.1.0 — 2026-10-05

Initial public repository.
