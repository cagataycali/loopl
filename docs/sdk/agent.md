---
title: "Agent"
description: "The agent loop: stream the model, run its tools, repeat until it answers. Call it, stream it, interrupt it, persist it."
---

# Agent

`Agent` is an actor. Give it a `Model` and tools; call it for the answer, or stream every event.

```swift
// snippet: compile
import Loopl

func ask(_ model: any Model) async throws {
    let agent = Agent(model: model,
                      tools: [CurrentTimeTool(), CalculatorTool()],
                      systemPrompt: "You are a concise assistant.")

    let result = try await agent("What is 23 × 47?")
    print(result.text)                           // the answer
    print(result.stopReason)                     // .endTurn
    print(result.metrics.cycleCount,             // model calls
          result.metrics.toolCallCount,
          result.metrics.accumulatedUsage.totalTokens)
}
```

## The loop

1. **Stream** the model. Text is yielded as it arrives; tool calls are assembled.
2. **Run tools** — every call in the turn, concurrently. Each call is checked against its tool's schema first: a broken call never reaches the tool, it gets an error result that says what was wrong, and the model usually fixes it next cycle.
3. **Repeat** while the model asks for tools. When it stops, you get an `AgentResult`.

There is no iteration cap and no loop detector. The bounds are the context window and cancellation. Throttling is retried (`ModelRetryStrategy`), an overflowing context is trimmed by the [conversation manager](hooks.md#conversation), and a reply cut off at `maxTokens` is kept in history while `MaxTokensReachedError` is thrown — so you can simply continue:

```swift
// snippet: compile
import Loopl

func askResilient(_ agent: Agent, _ prompt: String) async throws -> AgentResult {
    do { return try await agent(prompt) }
    catch is MaxTokensReachedError { return try await agent() }      // the partial turn is already in history
}
```

## Stream

```swift
// snippet: compile
import Loopl

func show(_ agent: Agent, _ prompt: String) async throws {
    for try await event in agent.stream(prompt) {
        switch event {
        case .text(let delta):          print(delta, terminator: "")
        case .toolStarted(let use):     print("\n→ \(use.name) \(use.input)")
        case .toolResult(let r):        print("← \(r.name): \(r.content.prefix(80))")
        case .throttle(let s):          print("busy, retrying in \(Int(s)) s")
        case .result(let r):            print("\n\(r.stopReason), \(r.metrics.cycleCount) cycles")
        default: break
        }
    }
}
```

| `AgentEvent` | when |
|---|---|
| `.startEventLoop(cycle:)` | each model call |
| `.text` · `.reasoning` | content as it streams |
| `.toolUseStream` → `.toolStarted` → `.toolResult` | one tool call, start to finish |
| `.modelMessage` · `.toolResultMessage` | messages appended to history |
| `.throttle(delay:)` · `.forceStop` | retry · unrecoverable stop |
| `.metrics` | tok/s, time to first token, context used |
| `.result` | last event |

For SwiftUI, `Transcript` folds events into rows and `LooplUI` draws them.

## Interrupts

A hook or a tool can pause the loop to ask a person.

- **`.suspend`** (default) — only that call waits; the stream stays alive and other tools keep running. Answer with `agent.resolve(interrupt:response:)`. [Tool approval](hitl.md) is this, with a card.
- **`.stop`** — the loop returns with `stopReason == .interrupt`; resume later. Finished tool results are kept, not re-run.

```swift
// snippet: compile
import Loopl

struct AskingTool: Tool {
    let name = "ask_budget"
    let description = "ask the human for a budget"
    let parameters: JSONValue = ToolSchema.object([:])
    func call(_ args: [String: JSONValue]) async throws -> String {
        let answer = try InterruptScope.interrupt("budget", reason: .string("how much may I spend?"))
        return "budget = \(answer.compact)"
    }
}

func runWithStop(_ model: any Model) async throws {
    let agent = Agent(model: model, tools: [AskingTool()], interruptMode: .stop)
    var result = try await agent("book the cheapest flight")
    while result.stopReason == .interrupt {
        let answers = result.interrupts.map { InterruptResponse(interruptId: $0.id, response: .number(500)) }
        result = try await agent.resume(answers)
    }
    print(result.text)
}
```

`InterruptScope.interrupt` throws the first time and returns the answer when the tool runs again — a tool is written once and resumes where it stopped.

## Persist

`Message` is `Codable`, and the history is the state. For metrics and pending work too, use [Checkpoints](checkpoints.md).

```swift
// snippet: compile
import Loopl
import Foundation

func save(_ agent: Agent, to url: URL) async throws {
    try JSONEncoder().encode(await agent.messages).write(to: url)
}

func restore(_ model: any Model, from url: URL) throws -> Agent {
    let messages = try JSONDecoder().decode([Message].self, from: Data(contentsOf: url))
    return Agent(model: model, messages: messages)
}
```
