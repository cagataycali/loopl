---
title: Hooks & conversation
description: Observe or veto every step with typed hooks; keep a long session inside the context window with a conversation manager.
---

# Hooks & conversation

## Hooks

Typed callbacks at every step of the loop. Register on `agent.hooks` or ship a `HookProvider`.

```swift
// snippet: compile
import Loopl

func observe(_ agent: Agent) async {
    await agent.hooks.addCallback(BeforeToolCallEvent.self) { event in
        if event.toolUse.name == "http" {
            event.cancelTool = "Network tools are disabled in this session."   // the model reads this as the tool result
        }
    }
    await agent.hooks.addCallback(AfterModelCallEvent.self) { event in
        if let stop = event.stopResponse { print("model stopped: \(stop.stopReason)") }
    }
}
```

```swift
// snippet: compile
import Loopl

/// Counts tool calls and messages — the shape of SlidingWindowConversationManager and ModelRetryStrategy.
final class Telemetry: HookProvider, @unchecked Sendable {
    private(set) var toolCalls = 0
    private(set) var messages = 0

    func registerHooks(_ registry: HookRegistry) {
        registry.addCallback(AfterToolCallEvent.self) { [self] _ in toolCalls += 1 }
        registry.addCallback(MessageAddedEvent.self)  { [self] _ in messages += 1 }
    }
}

func make(_ model: any Model) -> Agent {
    Agent(model: model, hooks: [Telemetry()])
}
```

| `HookEvent` | fires | mutable |
|---|---|---|
| `BeforeInvocationEvent` / `AfterInvocationEvent` | once per `agent(…)` | — |
| `BeforeModelCallEvent` / `AfterModelCallEvent` | each model call | `stopResponse` |
| `BeforeToolsEvent` / `AfterToolsEvent` | each tool round | — |
| `BeforeToolCallEvent` / `AfterToolCallEvent` | each tool | `cancelTool`, `selectedTool`, `result` |
| `MessageAddedEvent` | every message appended | — |

After-events run in reverse registration order, as in Strands.

## Conversation managers

A `ConversationManager` keeps the history inside the context window — `applyManagement` after each turn and `reduceContext` when the model throws `ContextWindowOverflowError`.

```swift
// snippet: compile
import Loopl

func longRunning(_ model: any Model) -> Agent {
    Agent(model: model,
          systemPrompt: "You are a research assistant. Keep going until the question is fully answered.",
          conversationManager: SlidingWindowConversationManager(windowSize: 60,
                                                                compressionThreshold: 0.6,
                                                                pinFirst: 2))   // keep the user's brief
}
```

- `SlidingWindowConversationManager` (default, 40 messages) drops the oldest turns, never splits a tool call from its result, and can pin the first *n* messages.
- `NullConversationManager` does nothing — you own the history.
- Overflow is silent to the user: the agent trims and retries the same cycle.

This replaces the iteration cap other SDKs use. A long agentic session is bounded by what fits, not by a counter.

## Transcript for UIs

`Transcript` folds `AgentEvent`s into `TranscriptItem`s (text, reasoning, tool rows with timing, metrics); `LooplUI` draws them.

```swift
// snippet: compile
import Loopl

@MainActor
func drive(_ agent: Agent, _ prompt: String, into transcript: inout Transcript) async throws {
    transcript.user(prompt)
    for try await event in agent.stream(prompt) {
        _ = transcript.apply(event)            // returns true when the visible list changed
    }
    print(transcript.items.count, transcript.lastResult?.stopReason as Any)
}
```
