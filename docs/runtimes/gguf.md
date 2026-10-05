# GGUF / llama.cpp (v2)

`GGUFModel` exists as a **stub** today: it is in the `LooplRuntimes` product so the `Model` picker and
catalog can describe GGUF entries, but `load()` throws `ModelError.unsupportedEnvironment("GGUF runtime
ships in loopl v2")`.

## Why v2 and not v1

- llama.cpp no longer ships a `Package.swift`; the SwiftPM path is the **xcframework** from each release
  (`llama-bNNNNN-xcframework.zip`, ~60 MB) wrapped as a local `binaryTarget`.
- The C API (`llama.h`) has no chat-template or tool-call handling. That lives in C++ `common/chat.h`
  (`common_chat_templates_init`, `common_chat_parse`), which is not exported — so either a C shim is built
  into the xcframework or the rendering/parsing is re-implemented in Swift. loopl's `ChatTemplate` +
  `ToolCallParser` are that re-implementation, which is why the MLX path shipped first.
- `n_ctx` allocates the KV cache up front; the right value has to be derived from
  `os_proc_available_memory()` *after* the model loads.

## What it will give you

- The widest model coverage (every Q4_K_M on the Hub; ~10–15 % larger than MLX 4-bit).
- Single-file downloads that resume trivially.
- Metal on A18 Pro, same GGML backend as the Mac.

Planned catalog entries (none gated): Qwen3 0.6B/1.7B/4B, Llama-3.2 1B/3B, gemma-3-1b-it, Phi-4-mini,
SmolLM2/3 — see the [models table](../models.md) for the GGUF rows once they are enabled.
