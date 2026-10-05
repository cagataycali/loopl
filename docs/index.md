---
title: loopl — agents that run on the phone
hide:
  - navigation
  - toc
---

<div class="loopl-home" markdown>

# loopl

<div class="loopl-hero" markdown>

<div markdown>

<span class="loopl-hero__eyebrow">:material-fire: native swift · edge inference</span>

<h1 class="loopl-hero__title">Agents that run <em>on the phone</em>.<br>No cloud, no login.</h1>

<p class="loopl-hero__lead">
<strong>loopl</strong> is a Swift agent SDK built for on-device inference — the Strands agent loop,
rewritten for Metal and the Neural Engine. Pick a public model from Hugging Face — no account, no token — hand the agent a few tools,
and let it run until the job is done. The same loop powers the free <strong>loopl</strong> iOS app.
</p>

<div class="loopl-hero__cta" markdown>
[Get started](getting-started/index.md){ .loopl-btn .loopl-btn--primary }
[:fontawesome-brands-github: GitHub](https://github.com/cagataycali/loopl){ .loopl-btn .loopl-btn--ghost }
<a class="loopl-badge" href="app/" title="App Store listing — coming soon (TestFlight first)">
<span>:fontawesome-brands-apple:</span><span><small>Free · coming soon on the</small><b>App Store</b></span>
</a>
</div>

<p style="margin-top:1rem;font-size:.8rem;opacity:.7">
Coming from Strands Agents? <a href="sdk/strands-mapping/">See how loopl compares →</a>
</p>

</div>

<div class="loopl-hero__code" markdown>

```swift
// snippet: compile(wrap,runtimes)
import Loopl
import LooplRuntimes

// Qwen3-1.7B at 4-bit: 968 MB on disk, runs on Metal
let spec = Catalog.loadBundled().models.first { $0.id == "qwen3-1.7b-4bit" }!
let dir = URL.documentsDirectory.appending(path: "models/\(spec.id)")   // where HFDownloader put it
let model = MLXModel()
try await model.load(spec, from: dir) { _ in }

let agent = Agent(model: model,
                  tools: [CurrentTimeTool(), CalculatorTool()],
                  systemPrompt: "You are a concise assistant.")

let q = "What time is it in Istanbul, and what's 23*47?"
for try await event in agent.stream(q) {
    switch event {
    case .text(let t):           print(t, terminator: "")
    case .toolStarted(let call): print("→ \(call.name)")
    case .toolResult(let r):     print("← \(r.content)")
    default: break
    }
}
```

</div>

</div>

<div class="loopl-strip" markdown>
<span>:material-apple: iOS 18+ · iPhone 15 Pro+ recommended</span>
<span>:material-wifi-off: works in airplane mode</span>
<span>:material-account-off: no account, ever</span>
<span>:material-chart-line-variant: zero analytics</span>
<span>:material-language-swift: Swift 6 · SwiftPM</span>
</div>

<div class="loopl-cards" markdown>

<div class="loopl-card" markdown>
:material-language-swift:
### Swift SDK
`Agent`, `Tool`, `Model`, `Message`, `AgentEvent` — a small, typed surface that mirrors Strands
naming where it is natural, and feels like Swift everywhere else. Actors, async streams,
`Sendable` all the way down.

[SDK reference →](sdk/index.md)
</div>

<div class="loopl-card" markdown>
:material-chip:
### On-device runtimes
**MLX Swift** for 4-bit Hugging Face models on the GPU, **Apple Foundation Models** on iOS 26 with
zero download, and **GGUF on llama.cpp** for the wider quantised ecosystem. One `Model` protocol, swap at runtime.

[Runtimes →](runtimes/index.md)
</div>

<div class="loopl-card" markdown>
:material-all-inclusive:
### The Strands loop, unlimited
A faithful Swift port of the Strands event loop — stream, run tools concurrently, recurse — with **no
iteration cap**. The context window (kept in check by a sliding-window conversation manager) and your
Stop button are the only bounds. Hooks, retries and `maxTokens` recovery included.

[The event loop →](sdk/event-loop.md)
</div>

</div>

## Why on-device? { .loopl-section-title }

<div class="loopl-compare" markdown>

<div class="loopl-card" markdown>
### What you get
- **Privacy by construction** — prompts, tool results and notes never leave the phone.
- **Latency you can feel** — first token in well under a second on an A18 Pro with a 1.7B model.
- **Works offline** — a model already on disk answers in airplane mode.
- **Free to run** — no API key, no metered tokens, no vendor bill.
</div>

<div class="loopl-card" markdown>
### What to expect
- Models are **0.6B–4B** parameters at 4-bit; 7B+ is a warning, not a default.
- Context is RAM-bound: **8k tokens** is the sweet spot on an 8 GB iPhone.
- Tool calling quality varies by family — Qwen3 and Llama 3.2 are the reliable ones.
- See the [models table](models.md) for size, context and tool-call support per model.
</div>

</div>

## One struct to a tool { .loopl-section-title }

```swift
// snippet: compile
struct Clock: Tool {
    let name = "current_time"
    let description = "Current date & time, optionally for an IANA time zone"
    let parameters = ToolSchema.object(["timezone": ToolSchema.string("e.g. Europe/Istanbul")])
    func call(_ args: [String: JSONValue]) async throws -> String {
        let tz = TimeZone(identifier: args["timezone"]?.stringValue ?? "") ?? .current
        return Date().formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: tz))
    }
}
```

The schema is handed to the model's own chat template (Qwen/Hermes `<tool_call>`, Llama 3.x) or listed in the
instructions for Apple Foundation Models and Gemma-class models; `ToolCallParser` normalises all three dialects —
you write the tool once.

[Tools & JSON schema →](sdk/tools.md){ .loopl-btn .loopl-btn--ghost }
[Browse the models →](models.md){ .loopl-btn .loopl-btn--ghost }
[Read the privacy policy →](privacy.md){ .loopl-btn .loopl-btn--ghost }

</div>
