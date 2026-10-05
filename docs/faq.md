---
title: FAQ
description: Short answers — price, phones, context size, the no-cap loop, MLX vs GGUF, simulator, tool-calling models, tokens, Strands.
---

# FAQ

??? question "Is it really free? What's the catch?"
    Free, no account, no in-app purchase, no analytics. The models are public Hugging Face weights; inference is your phone's. The SDK is open source under the repository licence.

??? question "Which iPhone do I need?"
    iOS 18+. 8 GB RAM (iPhone 15 Pro, 16, 16 Pro) runs ≤ 4B-parameter models at 4-bit with 8k context comfortably; Qwen3-1.7B is the sweet spot. iPhone 17 Pro (12 GB) fits 7–8B. Apple Intelligence needs iOS 26 on an eligible device.

??? question "Why does the context say 8,192 when the model supports 40,960?"
    The KV cache grows with context. `ModelSpec.ctxUsable8GB` is the budget that keeps a 4-bit model inside an 8 GB phone's memory limit; raise `GenerationParams.contextLength` if you have the RAM.

??? question "Does the agent really loop forever?"
    It loops until the model stops calling tools, the context is exhausted, or you stop it. No iteration cap, no loop detector — a phone has no API bill to protect and Stop is one tap away. [How the loop ends →](sdk/agent.md)

??? question "MLX or GGUF?"
    MLX: fastest on Metal, exact tokens, 4-bit Hugging Face repos — device only. GGUF via llama.cpp: the widest quantised ecosystem and the only one that runs on the simulator (CPU). [Measured speeds →](sdk/models.md#speed-measured-not-quoted)

??? question "Can I use it on the simulator?"
    The simulator has no Metal JIT, so `MLXModel` is unavailable there; `GGUFModel` runs on CPU. `availability()` tells you which.

??? question "Which models do tool calls well?"
    Qwen3 and Qwen2.5 (Hermes `<tool_call>` format), Llama-3.2 1B/3B, Phi-4-mini and Apple's model. Gemma 3 and SmolLM fall back to bare-JSON parsing — fine for one tool, flaky for many. The [models table](models.md) has a column.

??? question "Qwen3 answers with a long `<think>` block. Can I turn it off?"
    The catalog sets `enable_thinking: false` in `chatTemplateKwargs`; remove it if you want the monologue. It costs tokens.

??? question "Do I need a Hugging Face token?"
    No. The downloader is anonymous and public repos only; gated repos are not offered.

??? question "Where do model files go?"
    Application Support, excluded from iCloud backup. Delete a model from the Models tab.

??? question "How is this different from Strands?"
    It *is* the Strands event loop, in Swift, for on-device models — same events, hooks, executors and retry policy. Differences are listed in [Agent & event loop](sdk/agent.md#strands-loopl).

??? question "Can I use the SwiftUI components alone?"
    Yes — `LooplUI` is a separate product: transcript, tool rows, token meter, model picker, download rows.

??? question "Why Metal, not the Neural Engine?"
    The ANE is only reachable through Core ML, which handles the dynamic int4 KV-cache pattern badly. Apple's own Foundation Models runtime is the one ANE path for an LLM — which is why it is one of the three runtimes.
