---
title: loopl — agents that run on the device
description: loopl is the Swift SDK for agents that run on the iPhone — a local model, the agent loop and native tools. Offline, no account, no cloud.
hide:
  - navigation
  - toc
  - footer
---

<div class="l-home" markdown>

# loopl

<section class="l-hero">
<div class="l-hero__text">
<span class="l-eyebrow"><i class="l-dot"></i>Swift SDK · iOS 18+ · open source</span>
<h1 class="l-hero__title">Agents that run on the device<span>.</span></h1>
<p class="l-hero__lead">loopl is a Swift SDK for building agents that live on the iPhone. <b>The model, the loop and the tools</b> all run locally — offline, with no account and no cloud.</p>
<div class="l-actions">
<a class="l-btn l-btn--ink" href="start/">Get started</a>
<a class="l-link" href="https://github.com/cagataycali/loopl">GitHub</a>
<a class="l-link" href="app/">The app</a>
</div>
<div class="l-install"><code>.package(url: "https://github.com/cagataycali/loopl", from: "0.1.0")</code><button type="button" data-copy='.package(url: "https://github.com/cagataycali/loopl", from: "0.1.0")'>Copy</button></div>
</div>

<div class="l-stage" aria-label="An agent turn: the model calls two on-device tools, then answers">
<div class="l-stage__bar"><b>Qwen3-1.7B · MLX · on device</b><button type="button" class="l-replay" aria-label="Replay">Replay</button></div>
<div class="l-chat">
<div class="l-msg l-msg--you" data-step="you"><span class="l-msg__who">You</span><p>It's dark in here. Torch on — and how do I say "where is the exit?" in Turkish?</p></div>
<div class="l-calls">
<div class="l-call" data-step="call"><span class="l-state"></span><b>flashlight</b> on<i>on</i></div>
<div class="l-call" data-step="call"><span class="l-state"></span><b>translate</b> → tr<i>Çıkış nerede?</i></div>
</div>
<div class="l-msg l-msg--agent" data-step="answer"><span class="l-msg__who">loopl</span><p data-stream="The torch is on. In Turkish: “Çıkış nerede?”">The torch is on. In Turkish: “Çıkış nerede?”</p><span class="l-caret" aria-hidden="true"></span></div>
</div>
<p class="l-stage__foot">Illustration of one turn. <code>flashlight</code> and <code>translate</code> ship in LooplAppleTools; the speeds below are measured.</p>
</div>
</section>

<section class="l-sec" markdown>
<div class="l-sec__head l-reveal">
<div><span class="l-num">01 — The loop</span><h2>Model, tools, model. Until it's done.</h2></div>
<p>That is the whole algorithm. The model streams; if it asks for tools they run, their results go back, and it is called again. There is no iteration cap — the context window and your Stop button are the only bounds.</p>
</div>
<div class="l-loop">
<svg class="l-ring l-reveal" viewBox="0 0 420 340" role="img" aria-labelledby="ring-t">
<title id="ring-t">The agent loop: the model calls tools, the results return to the model, until it answers.</title>
<circle class="l-track" cx="210" cy="175" r="118" fill="none" stroke-width="1"/>
<path id="ring-p" d="M210 57 A118 118 0 1 1 210 293 A118 118 0 1 1 210 57" fill="none" stroke="none"/>
<circle class="l-spark" r="4"><animateMotion dur="3.6s" repeatCount="indefinite"><mpath href="#ring-p"/></animateMotion></circle>
<rect class="l-node" x="160" y="40" width="100" height="34" rx="17" stroke-width="1"><animate attributeName="stroke-width" values="1;2.2;1;1" keyTimes="0;.06;.2;1" dur="3.6s" repeatCount="indefinite"/></rect>
<text x="210" y="62" text-anchor="middle">model</text>
<rect class="l-node" x="160" y="276" width="100" height="34" rx="17" stroke-width="1"><animate attributeName="stroke-width" values="1;2.2;1;1" keyTimes="0;.06;.2;1" dur="3.6s" begin="1.8s" repeatCount="indefinite"/></rect>
<text x="210" y="298" text-anchor="middle">tools</text>
<text class="l-sub" x="350" y="179" text-anchor="middle">calls</text>
<text class="l-sub" x="70" y="179" text-anchor="middle">results</text>
<text class="l-sub" x="210" y="179" text-anchor="middle">no iteration cap</text>
<text class="l-sub" x="96" y="30" text-anchor="middle">prompt ↘</text>
<text class="l-sub" x="324" y="30" text-anchor="middle">↗ answer</text>
</svg>
<ol class="l-steps l-reveal">
<li><div><b>Stream</b><span>Text arrives token by token; tool calls are parsed from whatever dialect the model speaks.</span></div></li>
<li><div><b>Run tools</b><span>Every call in a turn runs concurrently. Calls are checked against each tool's schema first, so a malformed call becomes an error the model can read and fix.</span></div></li>
<li><div><b>Repeat</b><span>Results go back to the model. When it stops calling tools, you get the answer, the metrics and the full history.</span></div></li>
</ol>
</div>
</section>

<section class="l-sec" markdown>
<div class="l-sec__head l-reveal">
<div><span class="l-num">02 — Native tools</span><h2>The phone is the toolbox.</h2></div>
<p>Image generation, the torch, haptics, other apps, offline translation and speech ship with the SDK — and they are only the starting point.</p>
</div>
<div class="l-tools l-reveal">
<div class="l-tool"><code>generate_image</code><p>A picture from a prompt, via Image Playground.</p></div>
<div class="l-tool"><code>open_app</code><em>asks first</em><p>Opens another app with a deep link, passing context along.</p></div>
<div class="l-tool"><code>flashlight</code><p>Torch on, off or dimmed.</p></div>
<div class="l-tool"><code>vibrate</code><p>Haptic patterns: tap, success, heartbeat…</p></div>
<div class="l-tool"><code>generate_voice</code><p>Speaks with on-device voices, Personal Voice included.</p></div>
<div class="l-tool"><code>transcribe</code><p>Speech to text, offline.</p></div>
<div class="l-tool"><code>translate</code><p>Apple's offline translation packs.</p></div>
<div class="l-tool"><code>read_text</code><p>OCR on an attached photo.</p></div>
<div class="l-tool"><code>describe_image</code><p>Scene labels, faces, barcodes — Vision.</p></div>
<div class="l-tool"><code>remember</code> · <code>recall</code><p>Notes the agent keeps between chats.</p></div>
<div class="l-tool"><code>http</code><em>asks first</em><p>Any HTTPS request, behind a human approval card.</p></div>
<div class="l-tool"><code>calculator</code> · <code>current_time</code><p>Exact arithmetic, any time zone.</p></div>
</div>
</section>

<section class="l-sec" markdown>
<div class="l-sec__head l-reveal">
<div><span class="l-num">03 — Your own</span><h2>A tool is a Swift struct.</h2></div>
<p>A name, a description, a JSON schema and an async function. Hand it to an Agent next to the built-ins.</p>
</div>
<div class="l-split l-reveal" markdown>
<ul>
<li><b>Typed, actor-safe.</b> Swift 6 concurrency, async streams all the way down.</li>
<li><b>Human in the loop.</b> Any tool can ask before it acts; the approval card is a SwiftUI view.</li>
<li><b>Structured output.</b> Ask for a Decodable, get one back.</li>
<li><b>Hooks, checkpoints, tracing.</b> When you need them, not before.</li>
</ul>

<div markdown>

```swift
// snippet: compile
import Loopl

struct Battery: Tool {
    let name = "battery_level"
    let description = "Battery level, in percent."
    let parameters = ToolSchema.object([:])

    func call(_ args: [String: JSONValue]) async throws -> String {
        "87 %"
    }
}

func ask(_ model: any Model) async throws -> String {
    let agent = Agent(model: model, tools: [Battery()])
    let result = try await agent("Do I need to charge?")
    return result.text
}
```

</div>
</div>
</section>

<section class="l-sec" markdown>
<div class="l-sec__head l-reveal">
<div><span class="l-num">04 — Runtimes</span><h2>Three engines. One protocol.</h2></div>
<p>MLX on the GPU, llama.cpp for GGUF, or Apple's built-in model. Swap the engine, keep the agent. Any public Hugging Face repo loads the same way.</p>
</div>
<div class="l-stats l-reveal">
<div class="l-stat"><b>41<small>tok/s</small></b><span>MLX · Qwen3-1.7B 4-bit<br>iPhone 16 Pro</span></div>
<div class="l-stat"><b>33<small>tok/s</small></b><span>llama.cpp · Qwen3-1.7B Q4_K_M<br>iPhone 16 Pro</span></div>
<div class="l-stat"><b>0<small>MB</small></b><span>Apple Foundation Models<br>iOS 26 · nothing to download</span></div>
</div>
<p class="l-note">Single runs from the app's self-test, not averages. <a href="models/">All models →</a></p>
</section>

<section class="l-sec">
<div class="l-app">
<div class="l-reveal">
<span class="l-num">05 — The app</span>
<h2>Free on iPhone. Nothing collected.</h2>
<p class="l-app__lead">The SDK's showcase, open source. Pick a model, then talk to an agent that uses the phone — with the network off if you like.</p>
<ul>
<li><b>No account needed.</b> Public models, anonymous download — your own Hugging Face token is optional, for private repos.</li>
<li><b>No analytics.</b> App Store label: Data Not Collected.</li>
<li><b>Offline mode.</b> One switch refuses every network call.</li>
</ul>
<div class="l-actions"><a class="l-btn l-btn--ink" href="app/">About the app</a><a class="l-link" href="privacy/">Privacy</a></div>
</div>
<div class="l-phone l-reveal"><picture><source srcset="assets/app/03-tool.webp" type="image/webp"><img src="assets/app/03-tool.png" alt="The loopl app answering a question with two expanded tool rows" width="320" height="696" loading="lazy" decoding="async"></picture></div>
</div>
</section>

<section class="l-end l-reveal">
<h2>Build an agent that works in airplane mode.</h2>
<div class="l-actions"><a class="l-btn l-btn--ink" href="start/">Get started</a><a class="l-link" href="sdk/agent/">Read the docs</a></div>
</section>

<footer class="l-foot">
<span>© 2026 Çağatay Çalı · open source · no data collected</span>
<nav aria-label="Footer"><a href="start/">Start</a><a href="sdk/agent/">SDK</a><a href="models/">Models</a><a href="app/">App</a><a href="privacy/">Privacy</a><a href="faq/">FAQ</a><a href="changelog/">Changelog</a><a href="api/">API</a><a href="https://github.com/cagataycali/loopl">GitHub</a></nav>
</footer>

</div>
