---
description: Agent — the Strands-style entry point of the loopl SDK. Build it with a model and tools, call it or stream it, read the result.
---

# Agent

`Agent` is the one object you talk to. It owns the conversation, the tools, the hooks and the
[event loop](event-loop.md); you give it a `Model` and ask questions. It is a Swift **actor**, so the
conversation state is safe to touch from any task.

```swift
public actor Agent {
    public let model: any Model
    public private(set) var tools: [any Tool]
    public private(set) var systemPrompt: String?
    public private(set) var messages: [Message]          // Strands agent.messages
    public let hooks: HookRegistry
    public let conversationManager: any ConversationManager
    public let toolExecutor: any ToolExecutor
    public let retryStrategy: ModelRetryStrategy?
    public private(set) var eventLoopMetrics: EventLoopMetrics

    public init(model: any Model,
                tools: [any Tool] = [],
                systemPrompt: String? = nil,
                messages: [Message] = [],
                conversationManager: any ConversationManager = SlidingWindowConversationManager(),
                hooks: [any HookProvider] = [],
                toolExecutor: any ToolExecutor = ConcurrentToolExecutor(),
                retryStrategy: ModelRetryStrategy? = ModelRetryStrategy())

    // run to completion
    public func callAsFunction(_ prompt: String) async throws -> AgentResult
    public func callAsFunction(_ messages: [Message]) async throws -> AgentResult
    public func callAsFunction() async throws -> AgentResult          // continue (e.g. after maxTokens)

    // stream every step
    public nonisolated func stream(_ prompt: String) -> AsyncThrowingStream<AgentEvent, Error>
    public nonisolated func stream(_ messages: [Message]) -> AsyncThrowingStream<AgentEvent, Error>

    public func setTools(_ tools: [any Tool])
    public func setSystemPrompt(_ prompt: String?)
    public func setMessages(_ messages: [Message])
    public func reset()
}
```

The initializer mirrors Strands' `Agent(model=…, tools=…, system_prompt=…, messages=…, conversation_manager=…,
hooks=…, tool_executor=…)` argument for argument. There is **no** `max_iterations`, no budget, no loop detector —
see [why](event-loop.md#6-the-context-window-is-the-only-limit).

## Call it

```swift
// snippet: compile
import Loopl

func ask(_ model: any Model) async throws {
    let agent = Agent(model: model,
                      tools: [CurrentTimeTool(), CalculatorTool()],
                      systemPrompt: "You are a concise assistant.")

    let result = try await agent("What time is it in Istanbul, and what is 23 × 47?")
    print(result.text)                               // the final assistant text
    print(result.stopReason)                         // .endTurn
    print(result.metrics.cycleCount,                 // model calls in this invocation
          result.metrics.toolCallCount,              // tools that ran
          result.metrics.accumulatedUsage.totalTokens)
}
```

`agent("…")` is `callAsFunction` — the same `agent("…")` you write in Strands Python. It appends the user turn,
runs the loop until the model stops calling tools, and returns an `AgentResult`:

```swift
public struct AgentResult: Sendable, Hashable {
    public var stopReason: StopReason        // endTurn · stopSequence · contentFiltered · cancelled (maxTokens throws instead)
    public var message: Message              // the last assistant message
    public var metrics: EventLoopMetrics
    public var text: String { message.text }
}

public struct EventLoopMetrics: Sendable, Hashable, Codable {
    public var cycleCount: Int               // Strands EventLoopMetrics.cycle_count
    public var toolCallCount: Int
    public var accumulatedUsage: Usage       // inputTokens · outputTokens · totalTokens
    public var accumulatedLatencyMs: Double
    public var last: Metrics                 // the last model call: ttft, tok/s, context used/max
}
```

## Stream it

For a UI you want every token and every tool call as it happens:

```swift
// snippet: compile
import Loopl

func show(_ agent: Agent, _ prompt: String) async throws {
    for try await event in agent.stream(prompt) {
        switch event {
        case .text(let delta):          print(delta, terminator: "")
        case .reasoning(let delta):     print("💭 \(delta)", terminator: "")
        case .toolStarted(let use):     print("\n→ \(use.name) \(use.input)")
        case .toolResult(let r):        print("← \(r.name): \(r.content.prefix(80))")
        case .throttle(let s):          print("⏳ model busy, retrying in \(Int(s)) s")
        case .forceStop(let why):       print("✗ \(why)")
        case .result(let r):            print("\n— \(r.stopReason), \(r.metrics.cycleCount) cycles")
        default: break
        }
    }
}
```

`stream` is `nonisolated` and returns immediately; the loop runs inside the stream's task. Leaving the `for` loop
(or cancelling the surrounding `Task`) cancels the model and any running tools — that is the app's Stop button.
The full event vocabulary is on [Messages & stream events](messages-events.md).

## Conversation state

`agent.messages` is the whole history as `Message` values (user / assistant / tool-result turns; the system prompt
is kept beside it). It persists across calls, so the second `agent("…")` sees the first. Store it to resume later:

```swift
// snippet: compile
import Loopl
import Foundation

func save(_ agent: Agent, to url: URL) async throws {
    let data = try JSONEncoder().encode(await agent.messages)      // Message is Codable
    try data.write(to: url)
}

func restore(_ model: any Model, from url: URL) throws -> Agent {
    let messages = try JSONDecoder().decode([Message].self, from: Data(contentsOf: url))
    return Agent(model: model, messages: messages)
}
```

`reset()` clears the history and the metrics but keeps model, tools and system prompt.

### Continue after `maxTokens`

When the model hits its output cap, the loop recovers the partial message (a truncated tool call becomes a text
block that says so), appends it to `agent.messages` and throws `MaxTokensReachedError` — exactly Strands'
`MaxTokensReachedException` ([details](event-loop.md#4-maxtokens-recovery)). Catch it and call `try await agent()` with
no argument to continue from the history, like `agent(prompt=None)` in Strands:

```swift
// snippet: compile
import Loopl

func askResilient(_ agent: Agent, _ prompt: String) async throws -> AgentResult {
    do { return try await agent(prompt) }
    catch is MaxTokensReachedError { return try await agent() }      // the partial turn is already in history
}
```

## Pieces you can swap

| Parameter             | Default                             | Why you would change it                                           |
|-----------------------|-------------------------------------|-------------------------------------------------------------------|
| `conversationManager` | `SlidingWindowConversationManager()` | Pin more turns, change the 0.7 trim threshold, or `NullConversationManager()` for tests. [→](conversation-managers.md) |
| `toolExecutor`        | `ConcurrentToolExecutor()`          | `SequentialToolExecutor()` when tools share one resource (camera, BLE). |
| `retryStrategy`       | `ModelRetryStrategy()` 6 × 4 s→240 s | `nil` to fail fast, or your own delays.                           |
| `hooks`               | `[]`                                 | Telemetry, allow-lists, persistence — see [Hooks](hooks.md).      |

!!! strands "Strands → loopl"
    `Agent(model=…, tools=[…], system_prompt=…)` → `Agent(model:tools:systemPrompt:)` · `agent("hi")` → `try await agent("hi")` ·
    `agent.stream_async("hi")` → `agent.stream("hi")` · `result.stop_reason` → `result.stopReason` · `agent.messages` → `agent.messages`.
    Full table on the [Strands mapping](strands-mapping.md) page.
