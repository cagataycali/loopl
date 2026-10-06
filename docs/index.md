---
title: loopl — an agent that lives on your phone
description: loopl runs the model, the agent loop and native tools on the iPhone. Free on TestFlight, open source Swift SDK. Offline, no account, nothing collected.
hide:
  - navigation
  - toc
  - footer
---

<div class="l-home" markdown>

# loopl

<section class="l-hero l-hero--v2">
<div class="l-hero__text">
<span class="l-eyebrow"><i class="l-dot l-dot--ping"></i>Free on iPhone · iOS 18+ · open source · no account</span>
<h1 class="l-hero__title">An agent that lives on your phone<span>.</span></h1>
<p class="l-hero__lead">loopl runs <b>the model, the loop and the tools</b> on the device. It talks, uses the phone, asks before it acts — and works with the network off.</p>
<div class="l-actions">
<a class="l-btn l-btn--ink l-btn--tf" href="https://testflight.apple.com/join/uUNjfzW9" id="testflight"><svg class="l-mark" viewBox="0 0 1024 1024" aria-hidden="true"><path class="l-mark__loop" pathLength="1" d="M 801.324 706.796 A 327.68 327.68 0 1 1 675.84 269.181" fill="none" stroke="currentColor" stroke-width="128" stroke-linecap="round"/><g class="l-mark__flame" transform="rotate(-6 675.84 191.459) translate(546.304 -2.845) scale(259.072 388.608)"><path d="M 0.66 0 C 0.86 0.22 1 0.44 1 0.64 C 1 0.86 0.78 1 0.5 1 C 0.22 1 0 0.86 0 0.64 C 0 0.34 0.42 0.3 0.66 0 Z" fill="currentColor"/></g></svg>Get it on TestFlight</a>
<a class="l-link" href="sdk/agent/">Read the SDK docs</a>
</div>
<p class="l-micro">Public beta · nothing collected · works in airplane mode</p>
<ul class="l-proofs" aria-label="What loopl gives you"><li>Offline</li><li>Native tools</li><li>Asks first</li><li>Your own model</li><li>Open SDK</li></ul>
</div>
<div class="l-phone l-phone--hero" aria-label="The loopl app on an iPhone: a model answers with two on-device tool calls">
<div class="l-phone__screen">
<video class="l-phone__video" autoplay muted loop playsinline preload="metadata" poster="assets/app2/hero-dark-poster.jpg" data-light="assets/app2/hero-light" data-dark="assets/app2/hero-dark" width="393" height="852"><source src="assets/app2/hero-dark.webm" type="video/webm"><source src="assets/app2/hero-dark.mp4" type="video/mp4"></video>
</div>
</div>
</section>

<section class="l-story" aria-labelledby="story-t">
<div class="l-story__pin">
<div class="l-phone l-phone--story" aria-hidden="true">
<div class="l-phone__screen l-story__screens">
<figure class="l-story__screen is-on" data-screen="models"><picture><source srcset="assets/app2/models-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/models-dark.png" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/models-light.webp" type="image/webp"><img src="assets/app2/models-light.png" alt="Models tab: Browse Hugging Face, Train your own, Mine, Apple Intelligence on device, Qwen3 downloading" width="393" height="852" loading="lazy" decoding="async"></picture></figure>
<figure class="l-story__screen" data-screen="offline"><picture><source srcset="assets/app2/offline-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/offline-dark.png" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/offline-light.webp" type="image/webp"><img src="assets/app2/offline-light.png" alt="Chat in airplane mode: Qwen3-0.6B is ready, everything runs on this device" width="393" height="852" loading="lazy" decoding="async"></picture></figure>
<figure class="l-story__screen" data-screen="tool"><picture><source srcset="assets/app2/tool-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/tool-dark.png" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/tool-light.webp" type="image/webp"><img src="assets/app2/tool-light.png" alt="Two tool rows, current_time and calculator, expanded with arguments and results, then the answer" width="393" height="852" loading="lazy" decoding="async"></picture></figure>
<figure class="l-story__screen" data-screen="approval"><picture><source srcset="assets/app2/approval-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/approval-dark.png" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/approval-light.webp" type="image/webp"><img src="assets/app2/approval-light.png" alt="An approval card for a POST request with Approve, Deny and Edit buttons" width="393" height="852" loading="lazy" decoding="async"></picture></figure>
<figure class="l-story__screen" data-screen="vision"><picture><source srcset="assets/app2/vision-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/vision-dark.png" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/vision-light.webp" type="image/webp"><img src="assets/app2/vision-light.png" alt="A photo of a red circle and a blue square described by the model, then a calculator call" width="393" height="852" loading="lazy" decoding="async"></picture></figure>
<figure class="l-story__screen" data-screen="train"><picture><source srcset="assets/app2/train-running-dark.webp" type="image/webp" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/train-running-dark.png" media="(prefers-color-scheme: dark)"><source srcset="assets/app2/train-running-light.webp" type="image/webp"><img src="assets/app2/train-running-light.png" alt="Train your own: the stage ladder of a fine-tune running on Hugging Face for $0.09" width="393" height="852" loading="lazy" decoding="async"></picture></figure>
</div>
</div>
</div>
<div class="l-story__steps">
<div class="l-story__intro l-reveal"><span class="l-num">What you get</span><h2 id="story-t">Six things the app does. All on the phone.</h2></div>
<div class="l-step" data-screen="models"><span class="l-num">01</span><h3>Pick a model. Download once.</h3><p>Qwen, Gemma, Llama, DeepSeek — or Apple's built-in model with nothing to download. Your own private Hugging Face repos too.</p></div>
<div class="l-step" data-screen="offline"><span class="l-num">02</span><h3>Talk to it. Even in airplane mode.</h3><p>Tokens stream on the GPU. One switch refuses every network call; the agent keeps working.</p></div>
<div class="l-step" data-screen="tool"><span class="l-num">03</span><h3>It uses the phone.</h3><p>Torch, haptics, offline translation, speech, image generation, other apps. Every call is a row you can expand.</p></div>
<div class="l-step" data-screen="approval"><span class="l-num">04</span><h3>It asks before it acts.</h3><p>Anything that leaves the device — a request, another app — waits for your tap. Deny, and the model is told so.</p></div>
<div class="l-step" data-screen="vision"><span class="l-num">05</span><h3>Show it. Tell it.</h3><p>Send a photo to a vision model. Record a take and let it transcribe.</p></div>
<div class="l-step" data-screen="train"><span class="l-num">06</span><h3>Train it on your own conversations.</h3><p>Pick chats, push them to your private dataset, start a fine-tune on Hugging Face, download the result. From the phone.</p></div>
<div class="l-story__cta l-reveal"><a class="l-btn l-btn--ink l-btn--tf" href="https://testflight.apple.com/join/uUNjfzW9"><svg class="l-mark" viewBox="0 0 1024 1024" aria-hidden="true"><path class="l-mark__loop" pathLength="1" d="M 801.324 706.796 A 327.68 327.68 0 1 1 675.84 269.181" fill="none" stroke="currentColor" stroke-width="128" stroke-linecap="round"/><g class="l-mark__flame" transform="rotate(-6 675.84 191.459) translate(546.304 -2.845) scale(259.072 388.608)"><path d="M 0.66 0 C 0.86 0.22 1 0.44 1 0.64 C 1 0.86 0.78 1 0.5 1 C 0.22 1 0 0.86 0 0.64 C 0 0.34 0.42 0.3 0.66 0 Z" fill="currentColor"/></g></svg>Get it on TestFlight</a><a class="l-link" href="app/">About the app</a></div>
</div>
</section>


<section class="l-sec" markdown>
<div class="l-sec__head l-reveal">
<div><span class="l-num">01 — The SDK</span><h2>The same loop, in Swift.</h2></div>
<p>loopl is a Swift SDK first; the app is its showcase. Model, tools, model — until it's done. That is the whole algorithm. The model streams; if it asks for tools they run, their results go back, and it is called again. There is no iteration cap — the context window and your Stop button are the only bounds.</p>
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
<div class="l-tool"><code>transcribe</code><p>Speech to text, offline — record a take in the composer.</p></div>
<div class="l-tool"><code>translate</code><p>Apple's offline translation packs.</p></div>
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




<section class="l-end l-end--v2 l-reveal">
<svg class="l-mark l-mark--big" viewBox="0 0 1024 1024" aria-hidden="true"><path class="l-mark__loop" pathLength="1" d="M 801.324 706.796 A 327.68 327.68 0 1 1 675.84 269.181" fill="none" stroke="currentColor" stroke-width="128" stroke-linecap="round"/><g class="l-mark__flame" transform="rotate(-6 675.84 191.459) translate(546.304 -2.845) scale(259.072 388.608)"><path d="M 0.66 0 C 0.86 0.22 1 0.44 1 0.64 C 1 0.86 0.78 1 0.5 1 C 0.22 1 0 0.86 0 0.64 C 0 0.34 0.42 0.3 0.66 0 Z" fill="currentColor"/></g></svg>
<h2>Download it. Turn the network off. Ask it something.</h2>
<div class="l-actions l-actions--center"><a class="l-btn l-btn--ink l-btn--tf" href="https://testflight.apple.com/join/uUNjfzW9">Get it on TestFlight</a><a class="l-link" href="start/">Build with the SDK</a></div>
<p class="l-micro">Free · iOS 18+ · open source · nothing collected</p>
</section>

<footer class="l-foot">
<span>© 2026 Çağatay Çalı · open source · no data collected</span>
<nav aria-label="Footer"><a href="start/">Start</a><a href="sdk/agent/">SDK</a><a href="models/">Models</a><a href="app/">App</a><a href="privacy/">Privacy</a><a href="faq/">FAQ</a><a href="changelog/">Changelog</a><a href="api/">API</a><a href="https://github.com/cagataycali/loopl">GitHub</a></nav>
</footer>

</div>
