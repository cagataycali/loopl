# Budget & the unlimited loop

## Why there is no cap

Most agent frameworks stop after N iterations (Strands: `max_iterations`, often 8–10). That is a server-side safety
valve against runaway API bills. On a phone there is no bill: the model is yours, the GPU is yours, and the user is
holding a Stop button. loopl therefore runs **until the model stops calling tools or the caller cancels**. A task that
needs 40 tool calls gets 40 tool calls.

What replaces the cap:

1. **Cancellation** — the user's Stop button, your `Task.cancel()`, or simply leaving the `for try await` loop.
2. **A `Budget` you opt into** — iterations, tool calls, wall time, generated tokens; `.unlimited` by default.
3. **A `LoopDetector` that warns** when the model repeats an identical tool call. It never stops the loop on its own,
   because "call `recall` three times with the same key" is sometimes exactly right.

## Budget

```swift
public struct Budget: Sendable, Hashable {
    public var maxIterations: Int? = nil
    public var maxToolCalls: Int? = nil
    public var maxWallTime: TimeInterval? = nil
    public var maxGeneratedTokens: Int? = nil     // summed over the whole run
    public init(maxIterations: Int? = nil, maxToolCalls: Int? = nil,
                maxWallTime: TimeInterval? = nil, maxGeneratedTokens: Int? = nil)
    public static let unlimited = Budget()
}

var config = AgentConfig()
config.budget = Budget(maxIterations: 50, maxWallTime: 120)
let agent = Agent(model: model, tools: tools, config: config)
```

When a limit is reached the loop yields `.finished(iterations: n, reason: .budget)` **after** the current tool results
are appended, so `agent.messages` stays consistent. `AgentResult.reason == .budget` tells the caller which path ended it.

## LoopDetector

```swift
public struct LoopDetector: Sendable, Hashable {
    public var threshold: Int          // identical (name + arguments) calls in a row → warning
    public init(threshold: Int = 3)
}
```

`AgentConfig.loopDetector` is `LoopDetector()` by default; set it to `nil` to turn it off. When the same call (same
name, same compact-JSON arguments) repeats `threshold` times consecutively, the loop yields

> `.warning("tool 'calculator' called 3× in a row with identical arguments — the model may be stuck; stop it if this keeps going")`

The app shows it as an amber pill under the tool card and lights up Stop. If you *do* want the detector to end the
run, observe the warning and leave the loop — leaving cancels:

```swift
for try await event in agent.stream(prompt) {
    if case .warning = event { break }        // → the model stream and the tool see cancellation
}
```

## Context is the real limit

Every iteration appends an assistant turn and tool results. With `GenerationParams.contextLength = 8192` you get
roughly 30–60 tool calls before history must be trimmed. `agent.messages` is deliberately mutable so a host can condense
it (keep `.system`, the first `.user`, the newest N turns); the app's **Trim history** does exactly that. The runtimes
hand `contextLength` to the KV cache as `maxKVSize`, so an over-long conversation degrades instead of crashing.
