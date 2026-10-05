---
description: Your first loopl agent in Swift — pick a public model from the catalog, download it anonymously, load it on Metal, give the agent two tools, stream the answer.
---

# Your first agent

A public model on disk, two tools, and the stream of events the loop produces. Everything below compiles against
the package — the `// snippet: compile` blocks are checked in CI.

## 1 · Pick a model and get it on disk

```swift
// snippet: compile(runtimes)
import Loopl
import LooplRuntimes
import Foundation

/// Downloads a catalog model into Application Support (resumable, anonymous) and returns its folder.
func fetch(_ id: String) async throws -> (ModelSpec, URL) {
    let spec = Catalog.loadBundled().models.first { $0.id == id }!            // e.g. "qwen3-0.6b-4bit"
    let root = URL.applicationSupportDirectory.appending(path: "loopl/models/\(spec.id)")
    let hf = HFDownloader()                                                     // no token — public repos only
    for file in try await hf.files(for: spec) {
        try await hf.download(repo: spec.repo, file: file, to: root.appending(path: file.path)) { bytes in
            print("\(file.path): \(bytes) / \(file.size)")
        }
    }
    return (spec, root)
}
```

The catalog is the SDK's `models.json` ([the table](../models.md)): every entry is a public, non-gated repository, with
the context you can afford beside the weights on an 8 GB phone (`ctxUsable8GB`). `HFDownloader` resumes partial files
and refuses to open a socket when `NetworkPolicy.isOffline` is set.

## 2 · Load it

```swift
// snippet: compile(runtimes)
import Loopl
import LooplRuntimes
import Foundation

func loadMLX(_ spec: ModelSpec, at dir: URL) async throws -> MLXModel {
    let model = MLXModel()                                       // Metal — a real device, not the simulator
    try await model.load(spec, from: dir) { p in print("loading \(Int(p * 100)) %") }
    var params = GenerationParams()
    params.contextLength = spec.ctxUsable8GB                     // the KV budget for this device class
    if let t = spec.temperature { params.temperature = t }
    await model.updateConfig(params)
    return model
}
```

Prefer zero download? On iOS 26 `AppleFoundationModel()` loads Apple's on-device model with no files at all
(`load(spec, from: nil)`); check `AppleFoundationModel.availability()` first. GGUF files load the same way through
`GGUFModel()`. One `Model` protocol — the rest of this page does not care which you chose.

## 3 · Build the agent — same shape as Strands

```swift
// snippet: compile
import Loopl

func makeAgent(_ model: any Model) -> Agent {
    Agent(model: model,
          tools: [CurrentTimeTool(), CalculatorTool(), RememberTool(), RecallTool()],
          systemPrompt: "You are a concise assistant running on the user's phone.")
}
```

That is the whole configuration. No iteration cap to set, no budget: the default `SlidingWindowConversationManager`
keeps the history inside the context window and the loop runs until the model stops calling tools or you cancel.

## 4 · Call it, or stream it

```swift
// snippet: compile
import Loopl

func run(_ agent: Agent) async throws {
    // 4a · the simple call: await the final answer
    let result = try await agent("What time is it in Istanbul, and what is 23 × 47?")
    print(result.text)                     // "It is 05:41 on Sunday 5 October in Istanbul, and 23 × 47 = 1081."
    print(result.metrics.cycleCount)       // 2 — one tool round, then the answer

    // 4b · or stream every event — this is what the app's transcript consumes
    for try await event in agent.stream("Remember that answer under 'math', then recall it.") {
        switch event {
        case .startEventLoop(let cycle):  print("\n[cycle \(cycle)]")
        case .text(let t):                print(t, terminator: "")
        case .toolStarted(let use):       print("\n→ \(use.name) \(use.input)")
        case .toolResult(let r):          print("← \(r.content.prefix(80))\(r.isError ? "  ✗" : "")")
        case .metrics(let m):             if m.finished { print("\n\(m.generatedTokens) tok · \(Int(m.tokensPerSecond)) tok/s") }
        case .result(let r):              print("\n— \(r.stopReason)")
        default: break
        }
    }
}
```

## What happens inside

1. The user turn is appended; `BeforeInvocationEvent` hooks run.
2. The model streams. `StreamAssembler` builds the assistant message while `.text` deltas reach your UI; a
   `<tool_call>` the model writes is recognised by the family parser and becomes a native `toolUse` block.
3. `stopReason == .toolUse` → the tool uses run **concurrently**, their results are appended as one message,
   and the loop recurses to step 2. `stopReason == .endTurn` → `.result` and you are done.
4. If the model hits `maxTokens`, the partial message is recovered and appended and `MaxTokensReachedError` is thrown
   (call `agent()` to continue); if the model throws something
   transient, it is retried with backoff; if the prompt would overflow the context, the conversation manager trims first.

The full picture, with a diagram: [The event loop](../sdk/event-loop.md).

## Conversation state

`agent.messages` holds the whole exchange as `Message` values and survives across calls, so the next prompt sees the
previous answer. `await agent.reset()` forgets it. Messages are `Codable` — persist them and pass `messages:` to a new
`Agent` to resume ([Agent → Conversation state](../sdk/agent.md#conversation-state)).

## Add a tool

```swift
// snippet: compile
import Loopl
import Foundation

struct Battery: Tool {
    let name = "battery_level"
    let description = "The device's battery level in percent."
    let parameters = ToolSchema.object([:])
    func call(_ args: [String: JSONValue]) async throws -> String { "87 %" }   // UIDevice.current.batteryLevel in an app
}
```

`name`, `description`, a JSON-Schema `parameters` value and an async `call` — that is the `Tool` protocol. The schema is
rendered into the model's own tool dialect; the model's reply is parsed back for you. More on [Tools](../sdk/tools.md).

## No device handy?

`Loopl` (the core) is pure Swift and runs on a Mac: `swift build --target Loopl && swift test` at the repo root
exercises the whole loop with the scripted `FakeModel` in `Tests/` — 25-deep tool chains, parallel tools,
`maxTokens` recovery, retries, window trimming, hooks order. MLX needs a real GPU: the simulator has no Metal JIT,
so run `MLXModel` on an iPhone (or the Mac itself, which the package also supports).
