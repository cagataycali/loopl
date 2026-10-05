---
description: Map of the loopl Swift package — the Loopl core, LooplRuntimes and LooplUI products — and the design rules behind them.
---

# SDK overview

Three SwiftPM products in one package (`Package.swift` at the repo root, Swift 6 language mode, iOS 18+):

```
Loopl                   pure Swift (Foundation only) — builds on macOS and the simulator
├─ Agent                actor · the Strands event loop: stream → assemble → tools (concurrent) → recurse
├─ AgentEvent · AgentResult · EventLoopMetrics · StopReason
├─ Message · ContentBlock · ToolUse · ToolResult · Role · JSONValue
├─ StreamEvent · StreamAssembler · Metrics · Usage           the model-side vocabulary (Bedrock-shaped, as in Strands)
├─ Model                protocol (Actor): load · stream(messages, toolSpecs, systemPrompt) · unload · availability
├─ GenerationParams · ModelError · ContextWindowOverflowError · ModelThrottledError · EventLoopError
├─ Tool · ToolSpec · ToolSchema · ClosureTool · ToolError · built-ins (current_time · calculator · remember · recall · http_get)
├─ ToolExecutor         ConcurrentToolExecutor (default) · SequentialToolExecutor
├─ ConversationManager  SlidingWindowConversationManager (default, the only limiter) · NullConversationManager
├─ HookRegistry · HookProvider · Before/After{Invocation,ModelCall,Tools,ToolCall} · MessageAddedEvent
├─ ModelRetryStrategy   6 attempts, 4 s → 240 s backoff (Strands defaults)
├─ ToolCallParser · ToolCallStreamGate · ToolFamily (hermes · llama3 · generic) · PromptBuilder
├─ ModelSpec · Catalog (bundled models.json) · HFDownloader (anonymous, resumable, offline-aware) · NetworkPolicy
└─ Transcript           value-type reducer: Transcript.apply(AgentEvent) → items for a UI

LooplRuntimes           Apple platforms
├─ MLXModel             mlx-swift-lm · Metal · 4-bit Hugging Face repos
├─ AppleFoundationModel iOS 26 Foundation Models · zero download
└─ GGUFModel            llama.cpp (Metal) · single-file .gguf

LooplUI                 SwiftUI
├─ AgentTranscriptView · StreamingTextView · ToolCallCard · TokenMeter · ModelPickerRow · DownloadProgressRow
└─ LooplMark · LooplMarkShape · LooplDesign · LooplCard · Pill
```

| Page | What it covers |
|---|---|
| [Agent](agent.md) | `Agent(model:tools:systemPrompt:…)`, `try await agent("…")`, `agent.stream(…)`, `messages`, `reset`, what you can swap |
| [The event loop](event-loop.md) | the cycle (diagram), stop reasons, concurrent tools, `maxTokens` recovery, retries, why there is no cap |
| [Hooks](hooks.md) | the nine events, callbacks, `HookProvider` |
| [Messages & stream events](messages-events.md) | `Message`/`ContentBlock`, `StreamEvent`, `AgentEvent`, `Transcript`, `Metrics` |
| [Tools & JSON schema](tools.md) | `Tool`, `ToolSchema`, `ClosureTool`, built-ins, parsing per family, execution and errors |
| [Model protocol](models.md) | implementing `Model`, errors the loop understands, `ModelSpec`/`Catalog`, `HFDownloader`, `GenerationParams` |
| [Conversation managers](conversation-managers.md) | `SlidingWindowConversationManager` (trim rules, proactive threshold), `NullConversationManager`, your own |
| [Strands mapping](strands-mapping.md) | the table: Strands Python / TypeScript ↔ loopl Swift |

## Design rules

- **Actors, not locks.** `Agent` and every `Model` are actors; `stream` is `nonisolated` and returns an
  `AsyncThrowingStream`, so a SwiftUI view can iterate it directly.
- **The loop is Strands'.** Same cycle, same stop reasons, same hooks, same conversation manager, same retry defaults —
  only the names are Swift. There is no iteration cap because the context window and cancellation already bound the loop.
- **Errors go to the model first.** A tool that throws becomes a `ToolResult` with `status == .error` that the model reads.
  Only model failures that survive the retry strategy end the loop, and they end it with `.forceStop` + `.result`, not a crash.
- **No hidden network, no account.** `Loopl` opens a socket only in `HFDownloader`, only to `huggingface.co`, only for the
  public repository you named — anonymously — and refuses when `NetworkPolicy.isOffline` is set.
