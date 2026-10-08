---
title: "Tracing"
description: "OpenTelemetry-shaped spans for every model call and tool, built from hooks. No dependency, nothing sent."
---

# Tracing

`Tracer` is a `HookProvider`. Add it and every run becomes a span tree.

```swift
// snippet: compile
import Loopl

func traced(_ model: any Model) async throws {
    let tracer = Tracer(agentName: "chat")
    let agent = Agent(model: model, tools: [CalculatorTool()], hooks: [tracer])
    for try await event in agent.stream("What is 23 × 47?") {
        if case .metrics(let m) = event { tracer.record(m, runtime: .mlx, modelId: "qwen3-1.7b-4bit") }
    }
    for span in tracer.spans {
        print(span.name, Int(span.durationMs ?? 0), "ms", span.status.rawValue)
    }
}
// chat 412 ms ok · execute_tool calculator 1 ms ok · chat 380 ms ok · invoke_agent chat 795 ms ok
```

One `invoke_agent` span per run, a `chat` child per model call, an `execute_tool` child per tool — parallel calls keep their own spans. Attribute names follow OpenTelemetry's GenAI conventions; `SpanAttribute` has the constants.

## Nothing leaves the phone

loopl doesn't link OpenTelemetry and never sends. `tracer.otlpJSON()` returns the OTLP/JSON body a collector accepts — posting it is your call.

```swift
// snippet: compile(wrap)
let tracer = Tracer()
let body = tracer.otlpJSON(serviceName: "my-app").compact
_ = body.count
```

Spans carry numbers and names — tokens, durations, tool names, stop reasons — not prompts or results. Content is opt-in, for debugging:

```swift
// snippet: compile(wrap)
let tracer = Tracer(agentName: "chat", options: .init(recordContent: true, keep: 256))
_ = tracer.spans
```

`keep` bounds memory (default 512); `keep: 0` with `onSpanEnd:` streams spans to your own sink.
