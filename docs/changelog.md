---
description: Versioned changelog for the loopl SDK, the iOS app and loopl.dev.
hide:
  - navigation
---

# Changelog

All notable changes to the **SDK** (`Loopl`, `LooplRuntimes`, `LooplUI`), the **app** and this **site**.
Versions follow [SemVer](https://semver.org); dates are UTC. Pre-1.0, minor versions may break the API — each
breaking change is called out under **Changed** with the old → new symbol.

!!! info "Pre-release"
    loopl is in its first week. The SDK surface is settling; until `0.2.0`
    ships, treat the pages under *SDK* as the direction, and the changelog as the contract.

## Unreleased — human in the loop & `http`

- **App**: **Settings › Storage** — keep models on a USB-C drive. Grant one folder (`UIDocumentPickerViewController`, security-scoped bookmark re-opened each launch), see free space per volume, choose where downloads go (falls back phone ↔ drive by room), **Move to drive / Move to this iPhone** with a verified copy (size every file, SHA-256 up to 64 MB, source removed only after), and a drive that is away keeps its models in the catalog dimmed and undeletable; the loaded model's drive being pulled is a named error, not a crash. [Storage](app/storage.md).
- **SDK**: `ModelLocation`, `StorageBookmark`, `StorageManifest`, `StorageError`, `ExternalStorage` (`freeSpace(at:)`, `ensureSpace`, `makeBookmark` / `resolve`, `move(directory:to:verify:)` with rollback, streaming `sha256(of:)`).
- **App**: Settings › **Hugging Face** — paste a token, it is verified (`whoami-v2`) before it is kept (Keychain, this device only), shown with name · token label · `read / write / jobs` badges, removable in one tap. **Models › Mine** lists the account's MLX/GGUF repos (private badge) and downloads them through the same details sheet; Browse resolves private repos once signed in. Anonymous use is unchanged.
- **SDK**: `HFDownloader(token:)` / `HubCatalog(token:)` take an `HFTokenProvider` consulted per request — `Authorization: Bearer` goes only to `huggingface.co` and is scrubbed on the CDN redirect; 401/403 surface as `.signInRequired` (no token) or `.noAccess` (token). `HubCatalog.mine(author:)`, `Hit.isPrivate`. `HFAccount.signIn(_:)` / `signOut()` / `provider` and `WhoAmI.scopes` extend the shared `HFAccount` (`.gated` stays as a deprecated alias).
- **Site**: loopl.dev redesigned for absolute minimalism — one typeface, ink on paper, one accent, hairlines; a landing that replays an agent turn; every page rewritten at about half the length. Front-matter descriptions are quoted (an unquoted `: ` had leaked page metadata into the body). [Design](DESIGN.md).
- **Removed**: every repeat heuristic. `RepeatBreaker` (identical call in consecutive cycles refused, two refusals ended the turn) and `ToolCallRepeatGuard` (an already-answered call vetoed in the stream gate; the Apple FM runtime re-asked once when that left the turn empty) are gone, with `ToolCallStreamGate(suppress:)`. The loop has no heuristics: a call the model issues is a call that runs, and the model decides what to do next from complete, honest tool results — including errors, which name the missing or wrong argument. Owner decision 2026-10-06.
- **Fixed**: a failed tool call was invisible to the model. No chat template renders `ToolResult.status` (Qwen3 / Qwen3.5 / Gemma / Llama print `content` only; the `<tool_response>` fold and the Apple FM transcript did the same), so a small model saw `missing required parameter 'url'…` as just another result and re-issued the identical call. Every prompt path now renders errors through `ToolResult.promptContent` — text starts with `ERROR: `, the fold adds `status="error"` — and validation errors end with `Fix the arguments and call the tool again, or answer the user without it.` (`ToolResult.retryHint`). Apple FM stays in call mode after an errored cycle instead of being told "tools have already been run for you, answer in plain text" (which forbade a corrected retry). Measured on Qwen3.5-0.8B-4bit via the real `Agent` + `MLXModel` — see PR for the before/after table.
- **App**: hold a message. A user row → **Edit · Copy · Delete from here**; Edit turns the row into an inline editor (Cancel / **Save & regenerate**: the turn is replaced, everything after it removed, the agent asked again with tools and approvals as usual). An answer → **Copy · Retry**. Disabled with a hint while the agent is running; Reduce Motion crossfades. History keeps the rewritten thread with an *edited* mark (`SavedConversation.editedAt`).
- **SDK**: `Transcript.truncated(before:)` / `truncated(through:)`, `userTurn(before:)`, `messages` (the agent history rebuilt from the visible items — tool rows pair `toolUse`/`toolResult` 1:1, notes/approvals/reasoning stay UI-only). [Transcript for UIs](sdk/hooks.md#editing-a-message-after-the-fact).
- **LooplUI**: `TranscriptActions` + `AgentTranscriptView.transcriptActions(_:)`, `EditableUserTurn`, `UserTurnEditor`, `RetryableAssistantTurn`. `UserTurn(menu:)`. Fixed: an empty `.contextMenu {}` on a row swallowed the long-press.
- **Fixed** (MLX): tool specs reached the chat template with alphabetically sorted keys (`description` before `name`, `function` before `type`) because swift-jinja sorts plain dictionaries; measured on Qwen3.5-0.8B this alone made it pick `remember`/`recall` for http/time asks (right tool 11/24 → 24/24 with the canonical order). Specs are now rendered through `additionalContext` as ordered Jinja values, in the order the models were trained on.
- **Changed**: `http` reports a 4xx/5xx as an error result (`ERROR: HTTP 405 method not allowed for POST … — use GET …`, body kept) instead of a success result with the status buried above an HTML page. Measured: Qwen3.5-0.8B re-issued a 405'd POST 7 times when it arrived as a success.
- **SDK**: `MLXModel.setTrace(_:)` → `GenerationTrace` (the prompt exactly as the model saw it, special tokens kept, + raw output + rejected native calls) for audits and self-tests; `Tests/LooplRuntimesTests/ToolCallAuditTests.swift` runs the real `Agent` + `MLXModel` through 9 tool-calling scenarios when `LOOPL_AUDIT_DIR` points at a model.
- **Fixed**: `http` "missing required parameter 'url'" with Qwen3.5 — the model writes flat calls (`{"name": "http", "url": …}`) under the hermes prompt and its own XML dialect (`<function=http><parameter=url>…`) under its chat template; `ToolCallParser` now reads both (plus `{"http": {…}}`, `tool`/`tool_name` keys), `ToolValidation` maps `URL`/`uri`/`link`/`href`/`endpoint` → `url`, places a loose value into the one missing required key, and its complaint carries a concrete example. 31 verbatim shapes captured from Qwen3.5-0.8B, Qwen3-0.6B and Apple Foundation Models are pinned in `HttpCallShapesTests`. `HttpTool` accepts a schemeless host (`loopl.dev` → `https://loopl.dev`). `JSONValue.compact` no longer escapes `/`.
- **SDK**: `Tool.requiresApproval(for:)`, `ApprovalRequest` / `ApprovalDecision`, `ApprovalPolicy` (always · mutating · never + trusted hosts). The agent suspends a flagged call inside the actor, emits `.approvalRequested`, resumes on `agent.resolve(approval:)`; timeout (120 s) and cancellation deny; other concurrent tools keep running. [Human in the loop](sdk/hitl.md).
- **Changed**: `HttpGetTool` (`http_get`) → `HttpTool` (`http`: GET/HEAD/POST/PUT/PATCH/DELETE, headers, body, timeout, capped response). `http_get` stays one release as a deprecated alias.
- **LooplUI**: `ApprovalCard` (Approve · Deny · Edit) rendered inline by `AgentTranscriptView.onApproval`; `HapticEvent.approvalNeeded`.
- **App**: Settings › Network › **Ask before** (every request · writes only · never); the saved `http_get` toggle migrates to `http`.

## 0.3.0 — 2026-10-05 · docs & identity

- **Docs compacted**: 25 pages → 10 (Home · Start · SDK ×4 · Models · App · Privacy · FAQ · Changelog · API). Every old URL redirects.
- **Re-imagined visual system** ([design tokens](DESIGN.md)): warm paper & ink light, deep charcoal dark, one flame accent, self-hosted Inter Tight, 8-pt scale. No Google Fonts request, no gradients, no glass.
- Landing page rebuilt around a real captured agent run (iPhone 16 Pro, Qwen3-1.7B, 2 cycles / 4 concurrent tools).

## 0.2.0 — in progress (main, 2026-10-05)

Phase 2, driven by the first hands-on review of the app on an iPhone 16 Pro. Everything below is on `main`;
the TestFlight build that carries it is being cut.

### Changed
- **Event loop** — `Sources/Loopl` is the agent loop: stream → `StreamAssembler`
  → tools via a `ToolExecutor` (**concurrent** by default) → tool-result message → recurse. **No iteration cap, no loop
  detector.** The context window (`SlidingWindowConversationManager`, the only limiter) and cancellation bound the loop.
  44 tests on a scripted model: 25-deep tool chain, parallel tools, `maxTokens` recovery, retry/backoff, window trimming, hook order.
- **Vocabulary** — `Message {role, content: [ContentBlock]}`, `ToolUse`/`ToolResult`, `StreamEvent`, `StopReason`,
  `AgentEvent`, `EventLoopMetrics`/`Usage`. `Model.stream(_:toolSpecs:systemPrompt:)` returns
  `StreamEvent`s; tool-call markup is resolved inside each runtime by `ToolCallStreamGate`.
- **Max-tokens recovery** — the truncated assistant message is repaired and appended, then `MaxTokensReachedError` is
  thrown; `agent()` continues from the history.
- **Retries** — `ModelRetryStrategy` (6 attempts, 4 s → 240 s) on `ModelThrottledError`; `AgentEvent.throttle`.
- **Defaults** — `GenerationParams.maxTokens = nil` (until stop), context from the catalog's 8 GB budget, temperature per model card.
- **App** — chat is a document (no bubbles, no metrics strip; *Show performance details* adds a quiet footer), composer with
  interactive keyboard dismiss, first-launch download of `mlx-community/Qwen3-0.6B-4bit` with inline progress and auto-reload of
  the last model, Models tab → a tap-to-switch list, conversation history (sheet / iPad sidebar), new app icon + launch mark,
  App Store screenshot sets (6.9", 6.5", iPad 13"). `UIBackgroundModes` removed (plain `URLSession` downloads).
- **Package** — platforms iOS 18 / macOS 15; `LooplUI` builds on macOS.

### Added
- **Hooks** — `HookRegistry`/`HookProvider` with `BeforeInvocationEvent` / `AfterInvocationEvent`, `BeforeModelCallEvent` /
  `AfterModelCallEvent`, `BeforeToolsEvent` / `AfterToolsEvent`, `BeforeToolCallEvent` / `AfterToolCallEvent`, `MessageAddedEvent`.
- **Conversation managers** — `ConversationManager` protocol, `SlidingWindowConversationManager` (window 40, tool-result
  truncation, proactive trim at 0.7 × context, `pinFirst`), `NullConversationManager`.
- **GGUF runtime** — `GGUFModel` on the official llama.cpp xcframework `b11401` (Metal, `n_gpu_layers = 99`, sampler chain
  top-p → min-p → temperature, chat template via `llama_chat_apply_template`, token-by-token streaming, overflow mapped to
  `ContextWindowOverflowError`); `scripts/fetch-llama-xcframework.sh` vendors the framework (+ optional simulator slice).
  Catalog: Qwen3 0.6B/1.7B/4B, Llama 3.2 3B, Gemma 3 1B, SmolLM2 1.7B as Q4_K_M.
- **Docs** — loopl.dev rebuilt: brand mark, social cards, 404, instant navigation, this versioned changelog; every SDK page
  written from the sources with `// snippet: compile` samples typechecked in CI (`docs/check_snippets.sh`), a type-name drift
  gate (`docs/check_symbols.sh`), and the **DocC API reference** at [loopl.dev/api](https://loopl.dev/api/).

### Removed
- `AgentConfig`, `Budget`, `LoopDetector`, `FinishReason`, `ModelEvent` (replaced by the vocabulary above; one-commit
  deprecation shims in `Compat.swift` for `ToolUse(id:name:arguments:)`, `ToolResult(callId:…)`, `Message.assistant(text:toolCalls:)`).
- Hugging Face token: no token UI, no `Keychain`, `HFDownloader()` is anonymous — only public, non-gated repositories are listed.
- The demo (scripted) runtime and the "max iterations" setting; `FakeModel` now lives in `Tests/` only.

### Roadmap
- Device tok/s table for GGUF vs MLX on the same models.
- Background `URLSession` downloads (today a locked phone pauses a download).
- `SummarizingConversationManager` with the local model; Apple Foundation Models native `Tool` bridging.
- TestFlight → App Store listing (free).

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
