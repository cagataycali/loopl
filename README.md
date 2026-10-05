# loopl 🔁

**A native Swift agent SDK for edge inference — the Strands event loop, on-device — plus a free iOS app that runs
Hugging Face models offline.** Download a public model, run it fully offline with token streaming, and let it call
tools in an unlimited `stream → assemble → run tools → append → recurse` loop. Docs: **https://loopl.dev**

iOS 18+, Swift 6, SwiftUI. Bundle `technology.tiny.loopl`. No accounts, no tokens, no analytics.

## Packages
| Product | What |
|---|---|
| `Loopl` | The SDK core (Foundation only): `Agent`, the Strands event loop, `Model`/`Tool` protocols, hooks, tool executors, conversation managers, stream types, catalog, anonymous Hugging Face downloader. |
| `LooplRuntimes` | Engines: `MLXModel` (mlx-swift-lm, Metal), `AppleFoundationModel` (iOS 26 Apple Intelligence), `GGUFModel` (llama.cpp, official xcframework). |
| `LooplUI` | SwiftUI components: `AgentTranscriptView`, `ToolRow`, `MarkdownBody`, `TokenMeter`, … |

```swift
import Loopl
import LooplRuntimes

let model = MLXModel()                                     // or GGUFModel(), AppleFoundationModel()
try await model.load(spec, from: localDirectory) { _ in }  // spec from Catalog.loadBundled(); params = spec.defaultParams
let agent = Agent(model: model, tools: [CurrentTimeTool(), CalculatorTool()], systemPrompt: "Be brief.")

let result = try await agent("what time is it in Istanbul and what is 23*47?")
print(result.text, result.stopReason, result.metrics.cycleCount)

for try await event in agent.stream("and now in Tokyo?") {
    switch event {
    case .text(let t): print(t, terminator: "")
    case .toolStarted(let use): print("→", use.name, use.input)
    case .toolResult(let r): print("←", r.content)
    case .result(let r): print("\n", r.stopReason)
    default: break
    }
}
```

## The event loop (Strands, faithfully)
`Sources/Loopl` is a port of `strands-agents/harness-sdk` (`strands-py/src/strands/event_loop`, `agent`, `hooks`,
`tools/executors`, `agent/conversation_manager`). Python → Swift symbol table: `docs/sdk/strands-mapping.md`.

- **`Agent`** — `Agent(model:tools:systemPrompt:messages:conversationManager:hooks:toolExecutor:retryStrategy:)`;
  `agent("…")` / `agent([Message])` / `agent()` (continue) → `AgentResult { stopReason, message, metrics }`;
  `agent.stream(…)` → `AsyncThrowingStream<AgentEvent, Error>` (the last event is always `.result`).
- **`eventLoopCycle`** — model stream → `StreamAssembler` builds the assistant `Message` from `StreamEvent`s
  (`messageStart`, `contentBlockStart/Delta/Stop`, `messageStop(StopReason)`, `metadata`) → `toolUse`? run every
  `toolUse` block through the `ToolExecutor` (**concurrent by default**, `SequentialToolExecutor` optional), append the
  `toolResult` user message, recurse · `endTurn` → return · `maxTokens` → `recoverMessageOnMaxTokensReached` is appended
  and `MaxTokensReachedError` is thrown (call `agent()` to continue) · cancellation → `.cancelled`.
- **No caps. No loop detector.** The only limiter is the context window: `SlidingWindowConversationManager` (default)
  trims oldest turns — keeping `toolUse`/`toolResult` pairs intact, truncating big tool results first — proactively at
  0.7 × `model.params.contextLength` (token estimate) and reactively on `ContextWindowOverflowError`, then retries.
  `NullConversationManager` to opt out. Stop it by cancelling the task.
- **Hooks** — `HookRegistry` + `HookProvider`: `BeforeInvocation`/`AfterInvocation`, `BeforeModelCall`/`AfterModelCall`
  (`retry`), `BeforeTools`/`AfterTools`, `BeforeToolCall` (`cancelTool`, swap tool) / `AfterToolCall` (rewrite result),
  `MessageAdded`. After… callbacks run in reverse order.
- **Retry** — `ModelRetryStrategy` (hook provider): retryable `ModelThrottledError` → exponential backoff
  4 s → 8 → 16 → 32 → 64 (6 attempts, 240 s cap), surfaced as `AgentEvent.throttle(delay:)`.
- **`Model` protocol** = Strands `Model`: `stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?)
  -> AsyncThrowingStream<StreamEvent, Error>`, `params`/`updateConfig`, `load`/`unload`, `static availability()`.
  Text-only engines turn `<tool_call>` / `<|python_tag|>` / fenced / bare-JSON markup into `toolUse` blocks
  **provider-side** with `ToolCallStreamGate` (what Bedrock/OpenAI providers do natively) — the UI never sees markup.
- **`Tool`** — `name`, `description`, `parameters` (JSON Schema), `call(_:) async throws -> String`; `ClosureTool`,
  `ToolSchema`. Built-ins: `current_time`, `calculator` (own evaluator), `device_info`, `remember`/`recall`, `http_get`
  (refused while offline).
- **Defaults are maxed out**: `GenerationParams.maxTokens == nil` (until stop / window full), `contextLength` =
  the catalog's 8 GB recommendation, temperature per model card (`ModelSpec.defaultParams`).

Tests (`swift test`, macOS): 25-deep tool chain, concurrent/sequential ordering, max-tokens recovery + continue,
retry/backoff/give-up, sliding-window pair safety + overflow recovery, hook order/reversal/cancel/rewrite, cancellation
mid-stream and mid-tools, stream-gate chunk boundaries — all on a test-only `FakeModel` (Tests/LooplTests, not shipped).

## Runtimes
| Runtime | Status | Notes |
|---|---|---|
| **MLX** (`ml-explore/mlx-swift-lm` → `MLXLLM`, `MLXLMCommon`) | built | Metal; real device only. Loads **from the local directory only** — no network code in the file. Native tool-call events merged with the stream gate. |
| **Apple Foundation Models** | built, `@available(iOS 26)` | `SystemLanguageModel.default` / `LanguageModelSession.streamResponse`. Zero download, 4096-token window, manual tool prompting (`generic` family). Token counts are `chars/4` estimates (flagged). |
| **llama.cpp (GGUF)** | built | Official `ggml-org/llama.cpp` xcframework (release **b11401**), vendored by `scripts/fetch-llama-xcframework.sh`. `llama_model_load_from_file` (Metal, 99 layers), `llama_init_from_model` (n_ctx from the catalog, n_batch 512, flash-attn auto), the model's built-in chat template via `llama_chat_apply_template` (tools folded into the system prompt), sampler chain top-p → min-p → temperature → dist, token-by-token `llama_token_to_piece` → UTF-8 safe → `StreamEvent`s, EOG → `endTurn`, context full → `maxTokens`. One generation at a time on a dedicated queue. |

```sh
scripts/fetch-llama-xcframework.sh --with-sim   # once: official zip (sha256 pinned) + a simulator slice built from the same tag
```
Without `Vendor/llama.xcframework` everything still builds; `GGUFModel.availability()` then says it is not linked.
(The official zip has **no iOS-Simulator slice**, so a URL `binaryTarget` would fail every simulator build — hence the
path-based, gitignored vendor step.)

Tokenizer + chat templates for MLX: `huggingface/swift-transformers` (`Tokenizers`), bridged by hand to
`MLXLMCommon.Tokenizer` (we deliberately do **not** link `MLXHuggingFace`).

## Catalog
`App/Resources/models.json` (mirrored in `Tests/LooplTests/Fixtures`): **public repos only** — loopl downloads
anonymously, there is no token anywhere. MLX 4-bit rows (`mlx-community/*`), GGUF Q4_K_M single-file rows
(`unsloth/*`, `bartowski/*`, `file`), Apple FM. Default `qwen3-0.6b-4bit`. `ModelSpec.defaultParams` carries the
per-model context / temperature defaults.

## Build
```sh
brew install xcodegen
swift test                                              # SDK, macOS
xcodegen generate -s App/project.yml
xcodebuild -project App/LooplApp.xcodeproj -scheme loopl -destination 'generic/platform=iOS Simulator' build
DEVICE_ID=<udid> DEVELOPMENT_TEAM=K6B7JDYLLL scripts/build-on-device.sh   # install + launch on an iPhone
LOOPL_GGUF_DIR=/path/with/Qwen3-0.6B-Q4_K_M.gguf swift test --filter GGUFModelTests   # real llama.cpp on macOS
```
First build resolves `mlx-swift` (large; several minutes).

## Honesty
- No benchmarks are claimed; the (optional) performance sheet shows measured numbers for *your* run. Apple FM exposes
  no tokenizer, so its counts are `chars/4` estimates (labelled).
- `ctx_usable_8gb` in the catalog is a RAM budget guess until measured on device.
- `MaxTokensReachedError` is thrown exactly as Strands does; with `maxTokens == nil` it only fires when the window is
  full, after the sliding window could not trim any further.

Private repo of @cagataycali. Lane notes live in `~/.tiny/loopl-20261005/`.
