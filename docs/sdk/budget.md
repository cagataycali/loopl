# Budget & the unlimited loop

## Why there is no cap

Most agent frameworks stop after N iterations (Strands: `max_iterations`, often 8–10). That is a
server-side safety valve against runaway API bills. On a phone there is no bill: the model is yours,
the GPU is yours, and the user is holding a Stop button. loopl therefore runs **until the model stops
calling tools or the caller cancels**. A task that needs 40 tool calls gets 40 tool calls.

What replaces the cap:

1. **Cancellation** — the user's Stop button, your `Task.cancel()`, or the app going to the background.
2. **A `Budget` you opt into** — tokens, wall time, iterations; `.unlimited` by default.
3. **A `LoopDetector` that warns** when the model repeats an identical tool call. It never stops the loop
   on its own, because "call `recall` three times with the same key" is sometimes exactly right.

## Budget

```swift
public struct Budget: Sendable, Equatable {
    public var maxIterations: Int? = nil
    public var maxOutputTokens: Int? = nil        // summed over the whole run
    public var maxWallTime: Duration? = nil
    public static let unlimited = Budget()

    public enum Limit: Sendable, Equatable { case iterations(Int), outputTokens(Int), wallTime(Duration) }
}

let agent = Agent(model: model, tools: tools,
                  budget: Budget(maxIterations: 50, maxWallTime: .seconds(120)))
```

When a limit is reached the loop yields `.done(.budget(limit))` after the current tool results are
appended, so the transcript is consistent. At 80 % of any limit it yields `.warning(.budgetNearing(limit))`.

## LoopDetector

```swift
public struct LoopDetector: Sendable {
    public var window: Int = 6             // how many recent calls to compare
    public var repeats: Int = 3            // identical (name + input) calls within the window → warning
    public var enabled: Bool = true
    public static let `default` = LoopDetector()
    public static let off = LoopDetector(enabled: false)
}
```

A warning carries the repeated call: `.warning(.repeatedToolCall(name: "calculator", count: 3))`. The app
shows it as an amber pill under the tool card and lights up Stop. If you *do* want the detector to
end the run, observe the warning and cancel:

```swift
for try await event in agent.stream(prompt) {
    if case .warning(.repeatedToolCall(_, let n)) = event, n >= 5 { break }   // leaving the loop cancels
}
```

## Context is the real limit

Every iteration appends an assistant turn and tool results. On an 8 GB phone with an 8k usable context
you get roughly 30–60 tool calls before history must be trimmed. `Agent` throws
`ModelError.contextExceeded` rather than silently dropping messages; the app's **Trim history** action
keeps the system prompt, the first user message and the newest N turns. A built-in sliding-window
`ConversationManager` is on the roadmap (see [Changelog](../changelog.md)).
