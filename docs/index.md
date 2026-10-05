---
title: loopl — agents that run on the phone
description: A native Swift agent SDK for on-device LLMs — the Strands event loop, no iteration cap — plus a free iOS app. Any public Hugging Face model. No cloud, no account.
hide:
  - navigation
  - toc
  - footer
---

<div class="loopl-home" markdown>

# loopl

<section class="loopl-hero" markdown>

<div markdown>

<span class="loopl-kicker">Swift · on-device · open source</span>

<h1 class="loopl-hero__title">Agents that run<br><em>on the phone</em>.</h1>

<p class="loopl-hero__lead">
<strong>loopl</strong> is a Swift agent SDK for on-device models, and the free iOS app built on it. Strands event loop, no iteration cap, any public Hugging Face model. Nothing leaves the phone.
</p>

<div class="loopl-cta">
<a class="loopl-btn loopl-btn--primary" href="app/">Get the app</a>
<a class="loopl-btn loopl-btn--ghost" href="start/">Add the Swift package</a>
</div>

<p class="loopl-hero__meta">Free · TestFlight now, App Store listing pending · iOS 18+ · <a href="https://github.com/cagataycali/loopl">Open source on GitHub ↗</a></p>

</div>

<div class="loopl-demo" aria-label="A real agent run captured on an iPhone 16 Pro, replayed">
<div class="loopl-demo__bar"><b>Qwen3-1.7B · 4-bit · MLX</b><span>iPhone 16 Pro</span><button type="button" class="loopl-demo__replay" aria-label="Replay the run">↻ replay</button></div>
<p class="loopl-demo__you">you</p>
<p class="loopl-demo__q">what time is it in Istanbul and what is 23*47? then remember the answer under the key 'proof' and recall it</p>
<p class="loopl-demo__status" aria-live="polite">end_turn · 2 cycles · 5.8 s on device</p>
<div class="loopl-demo__tool" data-step="tool"><b>current_time</b> Europe/Istanbul <i>Mon 5 Oct 13:50 <span class="ok">✓</span></i></div>
<div class="loopl-demo__tool" data-step="tool"><b>calculator</b> 23*47 <i>1081 <span class="ok">✓</span></i></div>
<div class="loopl-demo__tool" data-step="tool"><b>remember</b> proof <i>remembered <span class="ok">✓</span></i></div>
<div class="loopl-demo__tool" data-step="tool"><b>recall</b> proof <i>proof: 1081 <span class="ok">✓</span></i></div>
<div class="loopl-demo__a" data-step="answer"><p data-text="1081">1081</p><span class="loopl-caret" aria-hidden="true"></span></div>
<p class="loopl-demo__foot" data-step="foot">4 tools in one turn, concurrent · 41 tok/s · TTFT 2.3 s · ctx 787 / 8192 — the app's <code>--selftest</code>, 2026-10-05</p>
</div>

</section>

<div class="loopl-strip">
<span>Runs in airplane mode</span>
<span>No account. No analytics.</span>
<span>No iteration cap</span>
</div>

<section class="loopl-sec" markdown>
<span class="loopl-kicker">How it works</span>
## One loop, until the job is done
A faithful Swift port of the Strands event loop. The context window and your Stop button are the only bounds.

<div class="loopl-how" markdown>
<figure class="loopl-loop" aria-labelledby="loop-title" role="img">
<svg viewBox="0 0 560 250" width="560" height="250" xmlns="http://www.w3.org/2000/svg" fill="none" stroke="currentColor" stroke-width="1.5" font-family="ui-monospace, SF Mono, Menlo, monospace" font-size="12">
<title id="loop-title">The event loop: prompt → model streams → tool use runs tools concurrently → results return to the model → end turn → answer</title>
<defs><marker id="arr" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0.5 L7.5 4 L0 7.5" fill="none" stroke="currentColor" stroke-width="1.2"/></marker>
<marker id="arrf" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0.5 L7.5 4 L0 7.5" fill="none" class="l-f" stroke-width="1.2"/></marker></defs>
<text x="280" y="22" text-anchor="middle" fill="currentColor" stroke="none" opacity=".6" font-size="10.5">no iteration counter · the loop ends when the model stops calling tools</text>
<rect x="10" y="80" width="96" height="40" rx="8"/><text x="58" y="105" text-anchor="middle" fill="currentColor" stroke="none">prompt</text>
<rect x="190" y="68" width="180" height="64" rx="10" stroke-width="2"/><text x="280" y="95" text-anchor="middle" fill="currentColor" stroke="none" font-weight="700">model</text><text x="280" y="115" text-anchor="middle" fill="currentColor" stroke="none" opacity=".6" font-size="10.5">streams text · tool_use</text>
<rect x="190" y="190" width="180" height="50" rx="8"/><text x="280" y="212" text-anchor="middle" fill="currentColor" stroke="none">tools</text><text x="280" y="229" text-anchor="middle" fill="currentColor" stroke="none" opacity=".6" font-size="10.5">all calls, concurrent</text>
<rect x="454" y="80" width="96" height="40" rx="8"/><text x="502" y="105" text-anchor="middle" fill="currentColor" stroke="none">answer</text>
<path d="M106 100 H184" marker-end="url(#arr)"/>
<path d="M370 100 H448" marker-end="url(#arr)"/><text x="409" y="90" text-anchor="middle" fill="currentColor" stroke="none" opacity=".7" font-size="10.5">end_turn</text>
<path d="M250 132 V184" marker-end="url(#arr)"/><text x="242" y="163" text-anchor="end" fill="currentColor" stroke="none" opacity=".7" font-size="10.5">tool_use</text>
<path class="l-f l-draw" d="M310 190 V138" marker-end="url(#arrf)" stroke-width="2"/><text class="l-f" x="318" y="163" fill="currentColor" stroke="none" font-size="10.5">tool_result → again</text>
</svg>
</figure>

<div class="loopl-steps" markdown>
<div class="loopl-step loopl-reveal" markdown>
<span class="loopl-step__n">1</span>
### Stream
The model streams text and tool-use blocks; `Transcript` renders each delta as it lands.
</div>
<div class="loopl-step loopl-reveal" markdown>
<span class="loopl-step__n">2</span>
### Run tools
Every call in the turn runs concurrently; results go back as one message.
</div>
<div class="loopl-step loopl-reveal" markdown>
<span class="loopl-step__n">3</span>
### Recurse
While the stop reason is `toolUse`, call the model again. `endTurn` yields the `AgentResult`.
</div>
</div>
</div>
</section>

<section class="loopl-sec" markdown>
<span class="loopl-kicker">SDK</span>
## Write an agent in twelve lines
`Agent`, `Tool`, `Model`, `Message`, `AgentEvent` — a small typed surface. Actors and async streams all the way down.

=== "Agent"

    ```swift
    // snippet: compile
    import Loopl

    func ask(_ model: any Model) async throws -> String {
        let agent = Agent(model: model,
                          tools: [CurrentTimeTool(), CalculatorTool()],
                          systemPrompt: "You are a concise assistant.")
        let result = try await agent("What time is it in Istanbul, and what is 23 × 47?")
        return result.text                                // 2 cycles: one tool round, then the answer
    }
    ```

=== "Tool"

    ```swift
    // snippet: compile
    import Loopl
    import Foundation

    struct Battery: Tool {
        let name = "battery_level"
        let description = "The device's battery level in percent."
        let parameters = ToolSchema.object([:])
        func call(_ args: [String: JSONValue]) async throws -> String { "87 %" }
    }
    ```

=== "Stream"

    ```swift
    // snippet: compile
    import Loopl

    func show(_ agent: Agent, _ prompt: String) async throws {
        for try await event in agent.stream(prompt) {
            switch event {
            case .text(let delta):        print(delta, terminator: "")
            case .toolStarted(let use):   print("→ \(use.name)")
            case .toolResult(let r):      print("← \(r.content)")
            default: break
            }
        }
    }
    ```

[Get started →](start.md){ .loopl-btn .loopl-btn--ghost }

</section>

<section class="loopl-sec" markdown>
<span class="loopl-kicker">Runs offline</span>
## Swap runtimes, keep your code
One `Model` protocol, three engines. Numbers from the app's self-test on real hardware — single runs, not averages.

<div class="loopl-grid loopl-grid--4" markdown>
<div class="loopl-stat loopl-reveal"><b>41 tok/s</b><span>Qwen3-1.7B 4-bit · MLX Swift · iPhone 16 Pro</span></div>
<div class="loopl-stat loopl-reveal"><b>33 tok/s</b><span>Qwen3-1.7B Q4_K_M · llama.cpp GGUF · iPhone 16 Pro</span></div>
<div class="loopl-stat loopl-reveal"><b>0 MB</b><span>Apple Foundation Models · iOS 26 · no download</span></div>
<div class="loopl-stat loopl-reveal"><b>4 tools</b><span>one turn, concurrent · the run above · 1 tool round</span></div>
</div>

<div class="loopl-models">
<span>Qwen3 0.6B · 1.7B · 4B</span><span>Llama 3.2 1B · 3B</span><span>Gemma 3 1B · 4B</span><span>Phi-4-mini</span><span>SmolLM3</span><span>DeepSeek-R1 1.5B</span><span class="more">+ any public repo, through the SDK</span>
</div>

[Models & runtimes →](sdk/models.md){ .loopl-btn .loopl-btn--ghost }
</section>

<section class="loopl-sec" markdown>
<span class="loopl-kicker">The app</span>
## Free. Nothing collected.
The SDK's reference client — on TestFlight now, App Store listing pending.

<div class="loopl-grid--2 loopl-grid" markdown>
<div class="loopl-phone"><picture><source srcset="assets/app/03-tool.webp" type="image/webp"><img src="assets/app/03-tool.png" alt="The loopl app: the question 'What time is it in Istanbul, and what is 23 × 47?', two expanded tool rows — current_time and calculator — and the answer 06:14 and 1081" width="320" height="696" loading="lazy" decoding="async"></picture></div>
<div markdown>
The same loop on the phone: the shot shows the two tool rows it ran for the Istanbul question. First launch fetches Qwen3-0.6B (335 MB) by itself. Then a document-style transcript, tool rows you can expand, a Models tab with 21 public models — any Hugging Face repo is next — and an offline switch that refuses every network call.

- **No sign-in, no token** — public models, anonymous download.
- **No analytics, no servers** — App Store label: *Data Not Collected*.
- **Open source** — the app is the SDK's worked example.

[About the app →](app/index.md){ .loopl-btn .loopl-btn--primary }
[Privacy →](privacy.md){ .loopl-btn .loopl-btn--ghost }
</div>
</div>
</section>

<section class="loopl-sec loopl-final" markdown>
## Build an agent that works in airplane mode.
<div class="loopl-cta">
<a class="loopl-btn loopl-btn--primary" href="start/">Get started</a>
<a class="loopl-btn loopl-btn--ghost" href="https://github.com/cagataycali/loopl">GitHub</a>
</div>
</section>

<footer class="loopl-footer">
<nav aria-label="Footer"><a href="start/">Get started</a><a href="sdk/agent/">SDK</a><a href="models/">Models</a><a href="app/">App</a><a href="privacy/">Privacy</a><a href="faq/">FAQ</a><a href="changelog/">Changelog</a><a href="api/">API</a><a href="https://github.com/cagataycali/loopl">GitHub</a></nav>
<p>© 2026 Çağatay Çalı · loopl is open source · no data collected · built on the <a href="https://github.com/strands-agents">Strands</a> event loop · <a href="DESIGN/">design tokens</a></p>
</footer>

</div>
