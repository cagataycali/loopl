---
title: Hooks & conversation
description: Observe or veto every step with typed hooks; keep a long session inside the context window with a conversation manager.
---

# Hooks & conversation

## Hooks

Typed callbacks at every step of the loop. Register on `agent.hooks`:

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

A reusable bundle of callbacks is a `HookProvider` — the shape `SlidingWindowConversationManager` and `ModelRetryStrategy` themselves use:

```swift
// snippet: compile
import Loopl

final class Telemetry: HookProvider, @unchecked Sendable {
    private(set) var toolCalls = 0
    func registerHooks(_ registry: HookRegistry) {
        registry.addCallback(AfterToolCallEvent.self) { [self] _ in toolCalls += 1 }
    }
}

func make(_ model: any Model) -> Agent { Agent(model: model, hooks: [Telemetry()]) }
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

A `ConversationManager` keeps the history inside the context window — `applyManagement` after each turn, `reduceContext` on `ContextWindowOverflowError`.

**The budget is per runtime.** `model.contextWindow` is the loaded model's window clamped by the runtime's own ceiling — Apple Intelligence is fixed at 4,096 tokens, an MLX or GGUF Qwen3 reports 8k–32k — and the manager sizes its window from that, never from a constant.

```swift
// snippet: compile
import Loopl

func longRunning(_ model: any Model) async -> Agent {
    let manager = SlidingWindowConversationManager(windowSize: 60, compressionThreshold: 0.6, pinFirst: 2)
    let ctx = await model.contextWindow                   // 4096 on Apple Intelligence
    print(manager.windowSize(forContextWindow: ctx),      // messages kept at that window
          TokenEstimator.isEstimate)                      // true — chars/4, never a tokenizer count
    return Agent(model: model, systemPrompt: "Keep going until the question is answered.",
                 conversationManager: manager)
}
```

Token counts here are an **estimate** (`TokenEstimator`: UTF-8 bytes / 4, plus a few per message), which is why trimming starts at `compressionThreshold` (0.7) of the window rather than at 100 %. Runtimes that tokenise report real `promptTokens` in `Metrics` *after* the call; Apple FM does not and flags `Metrics.estimated`.

Trim order: fat **tool results** are truncated to head + tail first, then the oldest turns slide out — never the system prompt, never the current user turn — and harder result truncation is the last resort before the error propagates. If a runtime refuses anyway, the loop reduces context and retries **once** (`Agent.maxContextReductions`, counted in `metrics.contextReductionCount`), the same shape as the `maxTokens` recovery.

- `SlidingWindowConversationManager` (default) — window ≤ 40 messages, pins the first *n*, never splits a tool call from its result.
- `NullConversationManager` — does nothing; you own the history.

This replaces the iteration cap other SDKs use: a session is bounded by what fits, not by a counter.

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
