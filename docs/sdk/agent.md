# Agent

```swift
public final class Agent: Sendable {
    public init(model: any Model,
                tools: [any Tool] = [],
                systemPrompt: String? = nil,
                budget: Budget = .unlimited,
                loopDetector: LoopDetector = .default,
                params: GenerationParams = .init())

    /// One-shot: run the loop to completion and return the final assistant message.
    public func callAsFunction(_ prompt: String) async throws -> AgentResult

    /// Streaming: every event the loop produces, in order.
    public func stream(_ prompt: String) -> AsyncThrowingStream<AgentEvent, Error>
    public func stream(messages: [Message]) -> AsyncThrowingStream<AgentEvent, Error>

    public var messages: [Message] { get }   // conversation so far
    public func reset()                      // forget the conversation (keeps model + tools)
}

public struct AgentResult: Sendable {
    public let message: Message      // the final assistant turn
    public var text: String          // its text blocks joined
    public let iterations: Int
    public let metrics: Metrics
    public let stopReason: StopReason
}

public enum StopReason: Sendable, Equatable {
    case answered            // model returned no tool call
    case cancelled           // the Task was cancelled
    case budget(Budget.Limit) // a cap you opted into was reached
}
```

## The loop, precisely

```swift
messages.append(.user(prompt))
var iteration = 0
while true {
    iteration += 1; yield .iteration(iteration)
    let (assistant, events) = try await model.stream(messages, tools: tools, params: params)   // → textDelta / toolUse*
    messages.append(assistant)
    let calls = assistant.toolUses
    if calls.isEmpty { yield .done(.answered); return }
    for call in calls {                                                                          // sequential, in order
        yield .toolUseStart(call)
        let result = await run(call)                                                             // never throws
        messages.append(.toolResult(result))
        yield .toolResult(result)
    }
    if let warning = loopDetector.observe(calls) { yield .warning(warning) }                     // warns only
    if let limit = budget.exceeded(iteration:, metrics:) { yield .done(.budget(limit)); return }
}
```

- **Tool calls run sequentially** in the order the model emitted them. Parallel tool execution is a
  future `Agent.Options`, not the default — on-device tools are usually cheap and ordering matters.
- **An unknown tool name** is answered with `ToolResult.error("unknown tool 'x'. Available: a, b, c")` so
  the model can self-correct.
- **Cancellation** is cooperative: cancel the `Task` iterating the stream; the current token stream and
  tool call see `Task.checkCancellation()` and the loop yields `.done(.cancelled)`.

## Concurrency

`Agent` is `Sendable` and serialises its own state; call it from any actor. Running two prompts on the
same agent concurrently is a programmer error and throws `AgentError.busy`. Create one agent per
conversation.

## Parameters

```swift
public struct GenerationParams: Sendable {
    public var maxTokens: Int? = nil          // nil = until EOS or context
    public var temperature: Float = 0.6
    public var topP: Float = 0.95
    public var repetitionPenalty: Float? = nil
    public var stop: [String] = []
    public var contextLength: Int? = nil      // nil = the model's usable default for this device
    public var templateKwargs: [String: JSONValue] = [:]   // e.g. ["enable_thinking": false] for Qwen3
}
```

Qwen3 ships with *thinking* on; the catalog entry sets `enable_thinking: false` for the agent loop so
tool calls come out as `<tool_call>` blocks, not inside a `<think>` monologue.
