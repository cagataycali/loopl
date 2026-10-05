# Your first agent

A model on disk, two tools, and the stream of events the loop produces.

```swift
import Loopl
import LooplRuntimes

// 1. Pick a model from the bundled catalog and make sure its files are on disk
//    (see "Downloading" in the Model protocol page, or let the loopl app do it).
let spec = Catalog.loadBundled().models.first { $0.id == "qwen3-1.7b-4bit" }!
let dir  = modelsRoot.appendingPathComponent(spec.id)        // Application Support/…/models/qwen3-1.7b-4bit

// 2. Load it into the MLX runtime (real device — the simulator has no Metal JIT).
let model = MLXModel()
try await model.load(spec, from: dir) { progress in print("load \(Int(progress * 100)) %") }

// 3. An agent — the same shape as Strands: model, tools, system prompt.
var config = AgentConfig()
config.family = spec.family                                   // .hermes for Qwen3
config.params.contextLength = spec.ctxUsable8GB               // 8192 on an 8 GB iPhone
let agent = Agent(model: model,
                  tools: [CurrentTimeTool(), CalculatorTool(), RememberTool(), RecallTool()],
                  systemPrompt: "You are a concise assistant running on the user's phone.",
                  config: config)

// 4a. The simple call: await the final answer.
let result = try await agent("what time is it in Istanbul and what is 23*47?")
print(result.text)                 // "It is Sunday, 5 October 2026 05:41 in Istanbul, and 23 × 47 = 1081."
print(result.iterations)           // 2  (one tool round, then the answer)

// 4b. Or stream every event — this is what the app's transcript consumes.
for try await event in agent.stream("remember that answer, then recall it") {
    switch event {
    case .iterationStarted(let n):     print("\n[iteration \(n)]")
    case .text(let t):                 print(t, terminator: "")
    case .toolStarted(let call):       print("\n→ \(call.name) \(call.arguments)")
    case .toolFinished(let r):         print("← \(r.content.prefix(80))\(r.isError ? "  ✗" : "")")
    case .warning(let w):              print("⚠️ \(w)")                    // loop detector
    case .metrics(let m):              if m.finished { print("\n\(m.generatedTokens) tok · \(Int(m.tokensPerSecond)) tok/s · ttft \(Int(m.ttftMs)) ms") }
    case .assistantMessage:            break
    case .finished(let n, let reason): print("done after \(n) iterations: \(reason)")
    }
}
```

## What happens inside

```
user prompt
   │
   ▼
┌──────────── Agent.stream ─────────────┐
│ messages += .user                      │
│ loop {                                 │
│   model.stream(messages, tools)  ───── .text / .metrics (/ .toolCall if native)
│   parse tool calls from the text       │
│   no calls?  → .finished(.answered)    │
│   run each tool  ───────────────────── .toolStarted / .toolFinished
│   messages += assistant + tool results │
│   loopDetector → .warning · budget → .finished(.budget)
│ }                                      │
└────────────────────────────────────────┘
```

There is **no iteration cap by default**. The loop ends when the model answers without a tool call, when you stop
iterating the stream (cancellation), or when a `Budget` you opted into is exhausted. See
[Budget & the unlimited loop](../sdk/budget.md).

## Conversation state

`Agent` keeps `messages` between calls, so the second prompt sees the first exchange:

```swift
_ = try await agent("Remember: my flight is LH 1234 at 07:40.")
let a = try await agent("When is my flight?")      // → "LH 1234 at 07:40"
await agent.reset()                                 // start over (keeps the system prompt)
```

## Add a tool

```swift
struct Weather: Tool {
    let name = "weather"
    let description = "Current weather for a city. Only works online."
    let parameters = ToolSchema.object(["city": ToolSchema.string("City name")], required: ["city"])
    func call(_ args: [String: JSONValue]) async throws -> String {
        guard let city = args["city"]?.stringValue else { throw ToolError("missing 'city'") }
        if NetworkPolicy.isOffline { throw ToolError("offline — tell the user you cannot check the weather") }
        return "Sunny, 22 °C in \(city)"
    }
}
```

Tool errors are **returned to the model as tool results** (`ToolResult.isError`), not thrown — the model gets to recover
or explain. See [Tools & JSON schema](../sdk/tools.md).

## No device handy?

`FakeModel(scripts: [...])` plays scripted turns and runs anywhere, including Linux CI and SwiftUI previews:

```swift
let agent = Agent(model: FakeModel(scripts: ["Hello from the script."]))
print(try await agent("hi").text)       // Hello from the script.
```
