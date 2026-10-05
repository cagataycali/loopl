# FAQ

??? question "Is it really free? What's the catch?"
    Yes. The app is free, has no in-app purchases, no account and no analytics. The SDK is open source
    in the same repository. The catch is physics: a phone runs 0.6–4B-parameter models, not GPT-class ones.

??? question "Which iPhone do I need?"
    Anything with ≥ 6 GB RAM runs the small models (Qwen3-0.6B/1.7B). An iPhone 15 Pro / 16 / 16 Pro
    (8 GB) is the sweet spot for the default. Apple Foundation Models needs an Apple-Intelligence device
    on iOS 26 with it enabled.

??? question "Why does the context say 8,192 when the model supports 40,960?"
    The KV cache costs ~112 KiB per token for Qwen3-1.7B; 40k tokens is ~4.4 GB on top of the weights.
    The usable default is `min(memoryBound / 2, 8192, model max)` so the model, the cache *and* the UI fit
    in an 8 GB phone's per-app limit. Raise it in *Agent → Context* if you have headroom.

??? question "Does the agent really loop forever?"
    It loops until the model stops calling tools or you stop it. In practice tasks end in 1–6 iterations;
    pathological ones hit the loop detector, which warns you and lights the Stop button. If you want a
    hard cap, set `AgentConfig.budget` — it is `.unlimited` by default on purpose. [Why →](sdk/budget.md)

??? question "Why is `GGUFModel` a stub?"
    llama.cpp's chat-template and tool-call code lives in C++ `common/` and is not exported through the
    C API, so Swift needs a shim or a re-implementation. MLX already parses tool calls natively, so it
    shipped first. [Details →](runtimes/gguf.md)

??? question "Can I use it on the simulator?"
    For UI, yes. For inference, no: MLX compiles Metal kernels at runtime and the simulator has no Metal
    JIT. Use `FakeModel(scripts:)` in previews and tests; use a device for real tokens.

??? question "Which models do tool calls well?"
    Qwen3 (any size) and Qwen2.5 with the Hermes `<tool_call>` format, Llama-3.2 1B/3B, Phi-4-mini and
    Apple's model. Gemma 3 and SmolLM fall back to bare-JSON parsing — fine for one tool, flaky for many.
    The [models table](models.md) has a column for it.

??? question "Qwen3 answers with a long `<think>` block first. Can I turn it off?"
    The catalog entry's `chatTemplateKwargs` sets `enable_thinking: false`, and `MLXModel` passes it to the chat
    template. Remove it from the spec if you want the monologue; it costs tokens and context.

??? question "Do I need a Hugging Face token?"
    No — nothing in the default catalog is gated. A token is only for gated repos you have access to, and
    it lives in the Keychain. [Hugging Face token →](app/hf-token.md)

??? question "Where do the model files go, and are they backed up?"
    `Application Support/loopl/models/`, excluded from iCloud backup. Not `Library/Caches` (iOS purges it)
    and not `Documents` (shows in Files).

??? question "How is this different from Strands?"
    Same event loop, same `Message`/`ContentBlock`/`ToolSpec` vocabulary — running on a phone, in Swift,
    with no iteration cap and memory as a first-class error. [Mapping table →](sdk/strands-mapping.md)

??? question "Can I use the SwiftUI components without the whole app?"
    Yes — add the `LooplUI` product: `AgentTranscriptView`, `ToolCallCard`, `TokenMeter`, `ModelPickerRow`,
    `DownloadProgressRow` on the `LooplDesign` tokens; feed them a `Transcript` built from `FakeModel` scripts in previews.

??? question "Why Metal and not the Neural Engine?"
    The ANE is only reachable via Core ML, which wants static shapes/fp16 and handles the dynamic int4
    KV-cache pattern badly. Apple's own Foundation Models runtime is the one path that uses the ANE for an
    LLM, and it is closed — that is why it is one of the runtimes. [Runtimes →](runtimes/index.md)
