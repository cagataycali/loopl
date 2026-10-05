# SDK overview

Three SwiftPM products in one package (`Package.swift` at the repo root, Swift 6 language mode, iOS 18 / macOS 14):

```
Loopl                  pure Swift (Foundation only) — builds on macOS, Linux, the simulator
├─ Agent               actor: stream → parse tool calls → run tools → append → repeat
├─ AgentEvent · AgentResult · FinishReason
├─ AgentConfig         budget (default .unlimited) · loopDetector (warns) · family · params
├─ Budget · LoopDetector
├─ Model               protocol (Actor): load(spec, from:) · stream(messages:tools:params:) · unload()
├─ ModelEvent · Metrics · GenerationParams · ModelError · RuntimeKind · RuntimeAvailability
├─ Tool                protocol: name · description · parameters (JSONValue) · call(args) -> String
├─ ToolSchema · ToolResult · ToolCall · ToolError · ClosureTool · JSONValue
├─ Message             enum: system / user / assistant(text:toolCalls:) / tool(result:callId:name:)
├─ ToolCallParser · ToolFamily (hermes · llama3 · generic) · PromptBuilder
├─ ModelSpec · Catalog (bundled models.json) · HFDownloader (resumable, offline-aware)
├─ built-in tools      CurrentTimeTool · CalculatorTool · RememberTool · RecallTool · HttpGetTool
├─ Transcript          value-type reducer: Transcript.apply(AgentEvent) → items for a UI
└─ FakeModel           scripted actor for tests, previews and the app's "Demo" switch

LooplRuntimes          Apple platforms
├─ MLXModel            mlx-swift-lm 3.32.3 · Metal · real device only
├─ AppleFoundationModel   iOS 26 Foundation Models · zero download
└─ GGUFModel           llama.cpp — v2 stub (availability() says so)

LooplUI                SwiftUI
├─ AgentTranscriptView(transcript) · StreamingTextView · UserBubble · ToolCallCard(call:result:)
├─ TokenMeter(metrics) · ModelPickerRow(spec:loaded:) · DownloadProgressRow(done:total:fileIndex:fileCount:)
└─ LooplDesign · LooplCard · Pill    (tiny-flame tokens)
```

| Page | What it covers |
|---|---|
| [Agent](agent.md) | `Agent(model:tools:systemPrompt:config:)`, `try await agent("…")`, `agent.stream(…)`, `messages`, `reset` |
| [Messages & events](messages-events.md) | `Message`, `ToolCall`, `ModelEvent`, `AgentEvent`, `Metrics` |
| [Tools & JSON schema](tools.md) | `Tool`, `ToolSchema`, `ClosureTool`, `ToolResult`, built-ins, how tools reach each model family |
| [Model protocol](models.md) | implementing `Model`, `ModelSpec`/`Catalog`, `HFDownloader`, `GenerationParams`, `FakeModel` |
| [Budget & the unlimited loop](budget.md) | why no cap, `Budget`, `LoopDetector`, cancellation |
| [Strands mapping](strands-mapping.md) | the table: Strands Python ↔ loopl Swift |

## Design rules

- **Actors, not locks.** `Agent`, every `Model` and `FakeModel` are actors; `stream` is `nonisolated` and returns an
  `AsyncThrowingStream`, so a SwiftUI view can iterate it directly.
- **Errors go to the model first.** A tool that throws becomes a `ToolResult` with `isError = true` and a `tool` message the
  model sees. Only transport failures (model not loaded, out of memory, cancelled) throw out of `stream`.
- **No hidden network.** `Loopl` opens a socket only in `HFDownloader`, only to `huggingface.co`, only for the repo you
  named — and refuses when `NetworkPolicy.isOffline` is set.
- **Mirror Strands where it reads naturally**, be Swift everywhere else. `agent("prompt")` is `callAsFunction`; tools are
  value types; the event loop is the same algorithm.
