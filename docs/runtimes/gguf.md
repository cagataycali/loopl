---
description: GGUFModel — loopl's llama.cpp runtime on the official ggml-org xcframework. Metal offload, single-file GGUF models, sampler chain, tool calls through the shared stream gate.
---

# GGUF / llama.cpp

`GGUFModel` runs any single-file **GGUF** model through [llama.cpp](https://github.com/ggml-org/llama.cpp), using the
**official xcframework** that ggml-org publishes with every release — no fork, no C++ shim. It is the runtime for the
widest model ecosystem: Q4_K_M quantisations, families nobody converted to MLX, files you already have.

```swift
// snippet: compile(runtimes)
import Loopl
import LooplRuntimes
import Foundation

func loadGGUF(_ spec: ModelSpec, dir: URL) async throws -> GGUFModel {
    let model = GGUFModel()
    print(GGUFModel.availability().reason)                    // "" on device; "simulator: CPU only…" in the simulator
    try await model.load(spec, from: dir) { p in print("\(Int(p * 100)) %") }   // dir contains spec.file (one .gguf)
    return model
}
```

## What it does

| Step            | How                                                                                                         |
|-----------------|-------------------------------------------------------------------------------------------------------------|
| Load            | `llama_model_load_from_file` with **`n_gpu_layers = 99`** on device (all layers on Metal); `0` in the simulator |
| Context         | `n_ctx = GenerationParams.contextLength` (≥ 512), `n_batch = n_ubatch = 512`, flash attention auto, threads = cores − 2 (≤ 6) |
| Prompt          | the model's own chat template via `llama_chat_apply_template` (ChatML fallback); tool specs are folded into the system prompt in the family's dialect, because the C API's template call has no `tools` argument |
| Prefill         | the tokenised prompt is decoded in `n_batch` slices; a prompt that does not fit throws `ContextWindowOverflowError` *before* decoding, and a KV-slot failure (`llama_decode` → 1) maps to the same error so the conversation manager can trim |
| Sampling        | sampler chain **top-p → min-p → temperature → dist** (greedy when `temperature ≤ 0`), seeded from `GenerationParams.seed` |
| Streaming       | one token at a time → `StreamEvent.contentBlockDelta(.text)`; the family's markup is resolved by `ToolCallStreamGate` into native `toolUse` blocks, exactly as in `MLXModel` |
| Metrics         | exact prompt/generated token counts, ttft and tok/s (`Metrics.estimated == false`)                              |
| Concurrency     | one generation at a time; a second caller gets `ModelThrottledError` (retryable — the loop backs off) instead of a crash |

All llama.cpp calls run on a dedicated serial queue off the Swift cooperative pool, since a decode blocks for seconds.

## Getting llama.cpp into your build

The xcframework is **not** committed. `Package.swift` declares a path-based `binaryTarget` named `llama` only when
`Vendor/llama.xcframework` exists, and `GGUFModel.swift` is wrapped in `#if canImport(llama)`:

```bash
scripts/fetch-llama-xcframework.sh             # device + macOS slices from the release zip (~62 MB), sha256-verified
scripts/fetch-llama-xcframework.sh --with-sim  # + build the iOS-Simulator slice with upstream's build-xcframework.sh (cmake, 10–20 min)
```

The pinned release is `b11401` (override with `LLAMA_TAG` / `LLAMA_SHA256`). Why not a URL `binaryTarget`? The official
zip ships `ios-arm64` (device) and `macos` slices but **no iOS-Simulator slice**, so SwiftPM would fail every simulator
link; vendoring lets the script add that slice when you need it. Without `Vendor/`, everything else in the package builds
and `GGUFModel.availability()` explains that llama.cpp is not in this build.

## Catalog entries

| Model                       | File                              | Family    | Size    |
|-----------------------------|-----------------------------------|-----------|---------|
| Qwen3 0.6B                  | `Qwen3-0.6B-Q4_K_M.gguf`          | `hermes`  | ~0.4 GB |
| Qwen3 1.7B                  | `Qwen3-1.7B-Q4_K_M.gguf`          | `hermes`  | ~1.1 GB |
| Qwen3 4B                    | `Qwen3-4B-Q4_K_M.gguf`            | `hermes`  | ~2.5 GB |
| Llama 3.2 3B Instruct       | `Llama-3.2-3B-Instruct-Q4_K_M.gguf` | `llama3` | ~2.0 GB |
| Gemma 3 1B it               | `gemma-3-1b-it-Q4_K_M.gguf`       | `generic` | ~0.8 GB |
| SmolLM2 1.7B Instruct       | `SmolLM2-1.7B-Instruct-Q4_K_M.gguf` | `generic` | ~1.1 GB |

Exact sizes and context budgets are in the generated [Models](../models.md) table. A GGUF `ModelSpec` carries `file`
— the one artefact `HFDownloader.files(for:)` fetches — and downloads resume like any other model.

!!! tip "MLX or GGUF for the same model?"
    On an A17 Pro/A18 the MLX 4-bit conversion is usually the faster of the two; GGUF Q4_K_M is a little larger and
    a little slower but is the format with the most models. Both run the same `Agent`, the same tools and the same
    tool-call parsing — switch in the app's Model list and compare tok/s in the debug sheet.
