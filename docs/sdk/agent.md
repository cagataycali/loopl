# Agent

```swift
public actor Agent {
    public let model: any Model
    public var tools: [any Tool]
    public var config: AgentConfig
    /// The conversation so far (system prompt first). Mutable so a host can trim/condense it.
    public var messages: [Message]

    public init(model: any Model, tools: [any Tool] = [], systemPrompt: String? = nil,
                config: AgentConfig = AgentConfig())

    /// Strands-style call: run to completion, return the final text + what happened.
    public func callAsFunction(_ prompt: String) async throws -> AgentResult

    /// Append a user turn and run the loop, streaming every step.
    public nonisolated func stream(_ prompt: String) -> AsyncThrowingStream<AgentEvent, Error>

    public func reset(systemPrompt: String? = nil)   // forget the conversation (keeps model + tools)
}

public struct AgentResult: Sendable {
    public var text: String
    public var iterations: Int
    public var toolResults: [ToolResult]
    public var metrics: Metrics
    public var reason: FinishReason
}

public enum FinishReason: String, Sendable { case answered, budget, cancelled }

public struct AgentConfig: Sendable {
    public var budget: Budget = .unlimited
    public var loopDetector: LoopDetector? = LoopDetector()   // nil turns it off
    public var family: ToolFamily = .hermes                    // tool-call dialect for manual prompting
    public var params = GenerationParams()
}
```

## Usage

```swift
let agent = Agent(model: model, tools: [CurrentTimeTool(), CalculatorTool()],
                  systemPrompt: "You are a concise assistant.")

let result = try await agent("what time is it in Istanbul and what is 23*47?")
print(result.text, result.iterations, result.toolResults.map(\.name))

for try await event in agent.stream("Plan my morning in three 25-minute blocks.") {
    switch event {
    case .iterationStarted(let n):      print("[\(n)]")
    case .text(let t):                  print(t, terminator: "")
    case .toolStarted(let call):        print("→ \(call.name) \(call.arguments)")
    case .toolFinished(let r):          print("← \(r.name): \(r.content.prefix(80)) (\(Int(r.durationMs)) ms)")
    case .warning(let w):               print("⚠️ \(w)")
    case .metrics(let m):               print("\(m.tokensPerSecond) tok/s · ttft \(m.ttftMs) ms")
    case .assistantMessage, .finished:  break
    }
}
```

## The loop, precisely

```
messages += .user(prompt)
iteration = 0
loop:
    iteration += 1                                  → .iterationStarted(n)
    for try await ev in model.stream(messages, tools, params)
        .text(t)      → accumulate, yield .text(t)
        .toolCall(c)  → native call (runtime parsed it)
        .metrics(m)   → yield .metrics(m)
    calls = native + ToolCallParser(family).parse(text).calls
    messages += .assistant(text:, toolCalls: calls)   → .assistantMessage
    if calls.isEmpty                                   → .finished(iterations, .answered); return
    for call in calls (sequential, in order)
        → .toolStarted(call)
        result = try await tool.call(call.arguments)   // thrown error → ToolResult(isError: true)
        messages += .tool(result:callId:name:)         → .toolFinished(result)
        loopDetector.observe(call)                     → .warning(text) if identical ×threshold
    budget.exceeded(iterations, toolCalls, elapsed, generated) → .finished(n, .budget); return
```

- **Tool calls run sequentially** in the order the model emitted them.
- **An unknown tool name** is answered with `error: unknown tool 'x'. Available: …` so the model can self-correct.
- **Cancellation** is cooperative: stop iterating the stream (or cancel the `Task`); the model stream and the current tool
  see `Task.checkCancellation()` and the loop yields `.finished(n, .cancelled)`.
- **Default is unlimited.** `AgentConfig.budget = .unlimited` means the loop ends only when the model answers without a
  tool call or you cancel. See [Budget & the unlimited loop](budget.md).

## Parameters

```swift
public struct GenerationParams: Sendable, Hashable {
    public var temperature: Float = 0.6
    public var topP: Float = 0.95
    public var maxTokens: Int = 1024         // per model turn
    public var contextLength: Int = 4096     // KV-cache cap handed to the runtime (maxKVSize)
}
```

The app sets `contextLength` from the catalog's `ctxUsable8GB` (8,192 for every MLX model on an 8 GB iPhone). Qwen3's
*thinking* is turned off per model via `ModelSpec.chatTemplateKwargs` (`enable_thinking: false`), not here.
