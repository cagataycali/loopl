---
title: "FAQ"
description: "Short answers: price, phones, context, the loop without a cap, MLX or GGUF, the simulator, which models call tools well."
hide:
  - navigation
---

# FAQ

??? question "Where do I get the app?"
    [TestFlight](https://testflight.apple.com/join/uUNjfzW9) — public beta, iOS 18+, no account. The App Store listing follows the 1.0 review. Or build `App/` from the [source](https://github.com/cagataycali/loopl).

??? question "Is it really free?"
    Yes. No account, no purchase, no analytics. The models are public weights; the compute is your phone's. The SDK is open source.

??? question "Which iPhone do I need?"
    iOS 18+. 8 GB phones (15 Pro, 16, 16 Pro) run up to 4B parameters at 4-bit with 8k context — Qwen3-1.7B is the sweet spot. 12 GB fits 7–8B. Apple's model needs iOS 26 on an eligible device.

??? question "Does the agent really loop until it's done?"
    Until the model stops calling tools, the context runs out, or you press Stop. There is no API bill to protect on a phone, so there is no iteration cap. [The loop →](sdk/agent.md#the-loop)

??? question "MLX or GGUF?"
    MLX is fastest on the GPU with exact token counts, device only. GGUF via llama.cpp has the widest choice of quantised models and also runs on the simulator. [Speeds →](sdk/models.md#speed)

??? question "Which models call tools well?"
    Qwen3, Llama 3.2 (1B, 3B), Phi-4-mini and Apple's model. The [models table](models.md) has a column for it.

??? question "Qwen3 thinks out loud. Can I turn it off?"
    The catalog sets `enable_thinking: false`; remove it from `chatTemplateKwargs` if you want the reasoning.

??? question "Do I need a Hugging Face token?"
    Not for public models — downloads are anonymous by default. Paste one under **Settings › Hugging Face** (verified, kept in this device's Keychain, sent only to `huggingface.co`) and your private repos download too; **Models › Mine** lists them.

??? question "Can I use the SwiftUI pieces alone?"
    Yes — `LooplUI` is its own product: transcript, tool rows, approval card, model picker.

??? question "Why the GPU and not the Neural Engine?"
    The Neural Engine is only reachable through Core ML, which handles a growing int4 KV cache badly. Apple's own model is the one Neural Engine path for an LLM — which is why it is one of the three runtimes.
