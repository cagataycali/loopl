# SDK overview

```
Loopl                  pure Swift, no UIKit — builds on macOS/Linux/simulator
├─ Agent               the loop: stream → parse tool calls → run tools → append → repeat
├─ Model               protocol: stream(messages:tools:params:) -> AsyncThrowingStream<ModelEvent, Error>
├─ Tool · ToolSpec     protocol + JSON-schema builder (`JSONSchema`), ToolInput / ToolResult
├─ Message · ContentBlock   system / user / assistant / tool, text + toolUse + toolResult blocks
├─ AgentEvent          textDelta, toolUseStart/Delta, toolResult, iteration, warning, turnEnd, done
├─ Budget · LoopDetector    optional caps; default = unlimited; detector warns, never stops
├─ ChatTemplate · ToolCallParser   per-family prompt rendering + parsing (hermes, llama3, gemma, plain JSON)
└─ FakeModel           scripted model for tests and SwiftUI previews

LooplRuntimes          Apple platforms only
├─ MLXModel            mlx-community/*-4bit from Hugging Face · Metal GPU · iOS 18+
├─ AppleFoundationModel   iOS 26 Foundation Models · zero download · native Tool bridging
└─ GGUFModel           llama.cpp xcframework · v2 (stub today)

LooplUI                SwiftUI, every component has a #Preview with fixture events
├─ AgentTranscriptView · StreamingTextView · ToolCallCard
└─ TokenMeter · ModelPickerRow · DownloadProgressRow
```

| Page | What it covers |
|---|---|
| [Agent](agent.md) | `Agent(model:tools:systemPrompt:)`, `agent("…")`, `agent.stream(…)`, history, cancellation |
| [Messages & events](messages-events.md) | `Message`, `ContentBlock`, `ModelEvent`, `AgentEvent`, `Metrics` |
| [Tools & JSON schema](tools.md) | `Tool`, `ToolSpec`, `JSONSchema`, `ToolInput`, `ToolResult`, built-ins |
| [Model protocol](models.md) | implementing `Model`, `GenerationParams`, `ModelError`, `FakeModel` |
| [Budget & the unlimited loop](budget.md) | why no cap, `Budget`, `LoopDetector`, cancellation |
| [Strands mapping](strands-mapping.md) | the table: Strands Python ↔ loopl Swift |

## Design rules

- **Everything is `Sendable`.** Agents run inside `Task`s; events cross actor boundaries.
- **Errors go to the model first.** A tool that throws becomes a `ToolResult.error` the model sees. Only
  transport failures (model crashed, out of memory, cancelled) throw out of `stream`.
- **No hidden network.** `Loopl` never opens a socket. `LooplRuntimes` talks to `huggingface.co` only
  when a model file is missing, and only to the repo you named.
- **Mirror Strands where it reads naturally**, be Swift everywhere else. `agent("prompt")` is
  `callAsFunction`; `agent.stream` is an `AsyncThrowingStream`; tools are value types with a static spec.
