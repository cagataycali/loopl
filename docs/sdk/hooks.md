---
description: loopl hooks — observe or alter every step of the agent loop with typed, Sendable events, exactly like Strands' HookRegistry.
---

# Hooks

Hooks are how you look inside the loop without forking it — Strands' `HookRegistry` / `HookProvider` /
`HookEvent` trio, in Swift. Every `Agent` owns a registry (`agent.hooks`); the conversation manager and the
retry strategy are themselves hook providers, which is why they can live outside the loop's core.

## Events

| Event                    | When                                                   | You can…                                              |
|--------------------------|--------------------------------------------------------|-------------------------------------------------------|
| `BeforeInvocationEvent`  | `agent(…)` / `agent.stream(…)` begins                   | read `messages`; set `cancel` to abort with a reason   |
| `MessageAddedEvent`      | a user, assistant or tool-result message is appended    | log, persist, mirror to a UI                          |
| `BeforeModelCallEvent`   | just before `model.stream`                              | inspect `projectedInputTokens` vs `contextWindow`, edit `systemPrompt`, `cancel` |
| `AfterModelCallEvent`    | after the assistant message is assembled (or the call failed) | read `stopResponse` / `error`; set `retry = true` to call the model again |
| `BeforeToolsEvent`       | before the message's tool uses are executed             | read the assistant `message`; `cancel`                 |
| `BeforeToolCallEvent`    | before **one** tool runs                                | swap `selectedTool` (mock/deny/route), `cancelTool` with a message the model will read |
| `AfterToolCallEvent`     | after one tool ran                                      | rewrite `result`, inspect `error`                      |
| `AfterToolsEvent`        | after all tool results are appended                     | metrics, haptics                                       |
| `AfterInvocationEvent`   | the invocation ends — with a `result` or an `error`     | clean-up                                               |

`After…` events run their callbacks in **reverse registration order** (`shouldReverseCallbacks`), so a provider that
wraps a step unwinds in the right order — same rule as Strands.

## Registering a callback

```swift
// snippet: compile
import Loopl

func observe(_ agent: Agent) async {
    await agent.hooks.addCallback(BeforeToolCallEvent.self) { event in
        if event.toolUse.name == "http_get" {
            event.cancelTool = "Network tools are disabled in this session."   // the model reads this as the tool result
        }
    }
    await agent.hooks.addCallback(AfterModelCallEvent.self) { event in
        if let stop = event.stopResponse { print("model stopped: \(stop.stopReason)") }
    }
}
```

Callbacks are `@Sendable (inout Event) async throws -> Void`: mutate the event to influence the loop, throw to abort it.

## A reusable provider

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

Pass providers at init (`Agent(model:…, hooks: [...])`) or later with `agent.hooks.addHook(provider)`. Registration order
is: conversation manager → retry strategy → your providers — identical to Strands' `Agent.__init__`.

!!! tip "Hooks are the extension point, not subclassing"
    `Agent` is an actor, not a class to subclass. Anything Strands does with a plugin — token budgets, tool allow-lists,
    persistence, tracing — is a `HookProvider` here. The loop itself stays untouched.
