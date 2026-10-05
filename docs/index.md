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

<h1 class="loopl-hero__title">Agents that run on the phone.<br>No cloud, no login.</h1>

<p class="loopl-hero__lead">
<strong>loopl</strong> is a Swift agent SDK built for on-device inference — the Strands agent loop,
rewritten for Metal and the Neural Engine. Pick a model from Hugging Face, hand the agent a few tools,
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
import Loopl
import LooplRuntimes

let agent = Agent(
    model: MLXModel("mlx-community/Qwen3-1.7B-4bit"),
    tools: [Clock(), Calculator()],
    systemPrompt: "You are a concise assistant."
)

for try await event in agent.stream("What time is it in Tokyo, and what's 17% of 240?") {
    switch event {
    case .textDelta(let text):        print(text, terminator: "")
    case .toolUseStart(let call):     print("→ \(call.name)")
    case .toolResult(let result):     print("← \(result.content)")
    case .turnEnd(let metrics):       print("\n\(metrics.tokensPerSecond) tok/s")
    default: break
    }
}
```

</div>

</div>

<div class="loopl-strip">
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
naming where it is natural, and feels like Swift everywhere else. Async streams, structured
concurrency, `Sendable` all the way down.

[SDK reference →](sdk/index.md)
</div>

<div class="loopl-card" markdown>
:material-chip:
### On-device runtimes
**MLX Swift** for 4-bit Hugging Face models on the GPU, **Apple Foundation Models** on iOS 26 with
zero download, and **GGUF / llama.cpp** on the roadmap. One `Model` protocol, swap at runtime.

[Runtimes →](runtimes/index.md)
</div>

<div class="loopl-card" markdown>
:material-all-inclusive:
### Unlimited agent loop
No `max_iterations = 8`. The loop runs until the model stops calling tools or *you* cancel.
Optional `Budget` caps for tokens, wall time and iterations, plus a loop detector that **warns**
on identical repeated calls — and never silently stops.

[Budget & the loop →](sdk/budget.md)
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

## Three lines to a tool { .loopl-section-title }

```swift
struct Clock: Tool {
    static let spec = ToolSpec(name: "current_time",
                               description: "Current date & time, optionally for an IANA time zone",
                               parameters: .object(["timezone": .string(description: "e.g. Asia/Tokyo")]))
    func call(_ input: ToolInput) async throws -> ToolResult {
        let tz = TimeZone(identifier: input["timezone"]?.stringValue ?? "") ?? .current
        return .text(Date().formatted(.dateTime.timeZone(tz)))
    }
}
```

The tool's JSON schema is rendered into the model's own chat template (Hermes/Qwen `<tool_call>`,
Llama 3.x, Gemma plain-JSON) or bridged natively to Apple's `Tool` protocol on iOS 26 — you write
it once.

[Tools & JSON schema →](sdk/tools.md){ .loopl-btn .loopl-btn--ghost }
[Browse the models →](models.md){ .loopl-btn .loopl-btn--ghost }
[Read the privacy policy →](privacy.md){ .loopl-btn .loopl-btn--ghost }

</div>
