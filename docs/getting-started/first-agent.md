# Your first agent

A model, two tools, and the stream of events the loop produces.

```swift
import Loopl
import LooplRuntimes

// 1. A model. Downloaded from Hugging Face on first use, cached in Application Support.
let model = MLXModel("mlx-community/Qwen3-1.7B-4bit")

// 2. An agent — the same shape as Strands: model, tools, system prompt.
let agent = Agent(
    model: model,
    tools: [Clock(), Calculator(), DeviceInfo()],
    systemPrompt: "You are a concise assistant running on the user's phone."
)

// 3a. The simple call: await the final answer.
let answer = try await agent("What's 17% of 240, and what time is it in Tokyo?")
print(answer.text)

// 3b. Or stream every event — this is what the app's transcript view consumes.
for try await event in agent.stream("Plan my morning: 3 tasks, 25 minutes each, starting now.") {
    switch event {
    case .textDelta(let t):            print(t, terminator: "")
    case .toolUseStart(let call):      print("\n→ \(call.name) \(call.input)")
    case .toolResult(let r):           print("← \(r.content.prefix(80))")
    case .iteration(let n):            print("\n[iteration \(n)]")
    case .warning(let w):              print("⚠️ \(w)")     // loop detector, budget nearing
    case .turnEnd(let m):              print("\n\(m.outputTokens) tok · \(m.tokensPerSecond) tok/s · ttft \(m.ttftMs) ms")
    case .done(let reason):            print("done: \(reason)")
    }
}
```

## What happens inside

```
user prompt
   │
   ▼
┌──────────── Agent.stream ────────────┐
│ messages += user                      │
│ loop {                                │
│   stream model(messages, tools)  ──── textDelta / toolUseStart / toolUseDelta
│   parse tool calls (native or text)   │
│   no calls?  → done(.answered)        │
│   run each tool  ──────────────────── toolResult
│   messages += assistant + tool results│
│   budget / loop detector  ─────────── warning
│ }                                     │
└───────────────────────────────────────┘
```

There is **no iteration cap by default**. The loop ends when the model answers without a tool call,
when the enclosing `Task` is cancelled, or when a `Budget` you opted into is exhausted. See
[Budget & the unlimited loop](../sdk/budget.md).

## Conversation state

`Agent` keeps its `messages` between calls, so the second prompt sees the first exchange:

```swift
_ = try await agent("Remember: my flight is LH 1234 at 07:40.")
let a = try await agent("When is my flight?")      // → "LH 1234 at 07:40"
agent.reset()                                      // start a new conversation
```

Pass `history: false` if you want each call to start fresh, or build your own `[Message]` and call
`agent.stream(messages:)`.

## Add a tool

```swift
struct Weather: Tool {
    static let spec = ToolSpec(
        name: "weather",
        description: "Current weather for a city. Only works online.",
        parameters: .object(["city": .string(description: "City name")], required: ["city"])
    )
    func call(_ input: ToolInput) async throws -> ToolResult {
        guard Reachability.isOnline else { return .error("offline — tell the user you cannot check the weather") }
        let city = try input.string("city")
        // … fetch …
        return .text("Sunny, 22 °C in \(city)")
    }
}
```

Tool errors are **returned to the model as tool results**, not thrown — the model gets to recover or
explain. See [Tools & JSON schema](../sdk/tools.md).
