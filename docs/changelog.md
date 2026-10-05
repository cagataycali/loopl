---
description: Versioned changelog for the loopl SDK, the iOS app and loopl.dev.
---

# Changelog

All notable changes to the **SDK** (`Loopl`, `LooplRuntimes`, `LooplUI`), the **app** and this **site**.
Versions follow [SemVer](https://semver.org); dates are UTC. Pre-1.0, minor versions may break the API — each
breaking change is called out under **Changed** with the old → new symbol.

!!! info "Pre-release"
    loopl is in its first week. The SDK surface is settling around the Strands event loop; until `0.2.0`
    ships, treat the pages under *SDK* as the direction, and the changelog as the contract.

## 0.2.0 — in progress

Phase 2, driven by the first hands-on review of the app on an iPhone 16 Pro.

### Changed
- **Event loop** — the agent loop is a faithful Swift port of the Strands `event_loop_cycle`: stream → assemble
  the assistant message from stream events → run tools **concurrently** when `stopReason == toolUse` → append
  the tool-result message → recurse. **There is no iteration cap and no loop detector.** The only bounds are
  the context window (a sliding-window conversation manager trims by token estimate) and cancellation.
- **Max-tokens recovery** — when a model stops on `maxTokens` mid tool call, the truncated assistant message is
  appended and the model is asked to continue (Strands `_recover_message_on_max_tokens_reached`).
- **Retries** — model errors are retried with exponential backoff (Strands' throttle path).
- **Defaults** — generation parameters default to the model card's maximum sensible values (context from
  the catalog's 8 GB recommendation, generate until stop).

### Added
- **Hooks** — `BeforeInvocation` / `AfterInvocation`, `BeforeModelCall` / `AfterModelCall`,
  `BeforeToolCall` / `AfterToolCall`, `MessageAdded`.
- **GGUF runtime** — `GGUFModel` on the official llama.cpp xcframework (Metal, `n_gpu_layers = 99`,
  sampler chain, token-by-token streaming, chat template via `llama_chat_apply_template`). Catalog gains
  Qwen3-1.7B Q4_K_M, Llama 3.2 3B, gemma-3-1b and SmolLM2 GGUF entries.
- **App** — automatic first-launch download of `mlx-community/Qwen3-0.6B-4bit` and auto-load of the last
  model; a clean reading layout (no bubbles, no metrics strip — a debug sheet instead); keyboard dismiss on
  swipe; new app icon and launch screen; iPad layout; Dynamic Type and VoiceOver passes; App Store screenshots.
- **Docs** — this site rebuilt for quality: social cards, 404, instant navigation, versioned changelog;
  SDK pages rewritten from the final sources with compiling snippets and a DocC API reference under `/api/`.

### Removed
- `Budget.maxIterations`, `LoopDetector` (and the "max iterations: 8" setting in the app).
- Hugging Face token: no token UI, no Keychain code — only **public, non-gated** repositories are listed.
- The demo (scripted) runtime; `FakeModel` now lives in `Tests/` only.

## 0.1.0 — 2026-10-05

Initial public repository: SDK, runtimes, UI kit, app and site in one night.

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
  First device proof on an iPhone 16 Pro with Qwen3-1.7B-4bit.
- **Docs** — [loopl.dev](https://loopl.dev) on GitHub Pages, generated models table (`docs/gen_models.py`), privacy policy.
