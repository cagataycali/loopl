---
title: Models & runtimes
description: One Model protocol, three on-device runtimes — MLX Swift, Apple Foundation Models, GGUF via llama.cpp — plus the catalog, the downloader and honest speed numbers.
---

# Models & runtimes

`Model` is an actor protocol: `load`, `stream`, `unload`, `updateConfig`. Three runtimes ship in `LooplRuntimes`; swap them at runtime.

| | `MLXModel` | `AppleFoundationModel` | `GGUFModel` |
|---|---|---|---|
| Weights | Hugging Face 4-bit safetensors | Apple's, on the device | any `.gguf` |
| iOS | 18+, device only (Metal) | 26+, Apple Intelligence on | 18+ (device: Metal · simulator: CPU) |
| Download | 0.3–2.3 GB | none | 0.4–2.5 GB |
| Context | 8k usable on 8 GB RAM | 4,096 hard | `n_ctx` = `GenerationParams.contextLength` |
| Tokens | exact | estimated (no tokenizer) | exact |
| Tools | chat template | prompted (manual) | chat template |

Call `availability()` first — it returns `RuntimeAvailability` with the reason when a runtime cannot run here (simulator, iOS < 26, Apple Intelligence off).

**Apple Foundation Models behaviour.** Tools are prompted in prose, never as JSON schemas. Greetings get a plain answer; a tool is called only when needed. A JSON-wrapped reply (`{"status":…,"message":…}`) is unwrapped into its sentence, a signature written as text (`current_time("…")`) is re-asked once, and a call the model already has the result for is never run again. Snapshots stream live — a revised snapshot arrives as `textReplace`. A tool whose `redundantWithRuntime` is `.appleFM` (`apple_intelligence`) is not offered here.

## Load

```swift
// snippet: compile(runtimes)
import Loopl
import LooplRuntimes
import Foundation

func loadMLX(_ spec: ModelSpec, at dir: URL) async throws -> MLXModel {
    let model = MLXModel()
    try await model.load(spec, from: dir) { p in print("loading \(Int(p * 100)) %") }
    var params = GenerationParams()
    params.contextLength = spec.ctxUsable8GB                     // the KV budget for this device class
    if let t = spec.temperature { params.temperature = t }
    await model.updateConfig(params)
    return model
}

func loadGGUF(_ spec: ModelSpec, dir: URL) async throws -> GGUFModel {
    let model = GGUFModel()
    print(GGUFModel.availability().reason)                    // "" on device; "simulator: CPU only…" in the simulator
    try await model.load(spec, from: dir) { p in print("\(Int(p * 100)) %") }   // dir contains spec.file (one .gguf)
    return model
}
```

`AppleFoundationModel().load(spec, from: nil)` loads nothing — the model is already on the phone.

## Catalog, Hub & download

`Catalog.loadBundled()` is the app's `models.json` — 21 public models, see the [table](../models.md). Anything else on Hugging Face goes through `HubCatalog`, anonymously:

```swift
// snippet: compile(wrap)
let hub = HubCatalog()
let hits = try await hub.search("qwen3", kind: .mlx)          // mlx-community/* sorted by downloads; .gguf for GGUF repos
let spec = try await hub.resolve(hits[0].id)                 // → ModelSpec: runtime, size, context, RAM need, tool family
```

`search` returns `HubCatalog.Hit`s (downloads, quantisation bits, context, estimated size, gated flag); `resolve` reads `config.json` or the GGUF header and builds a `ModelSpec` the runtimes accept. Results are cached (`HubCache`) so already-downloaded models resolve offline. `HFDownloader` then fetches the files, resumable; a complete file is skipped, so `load(spec, from:)` works offline afterwards. `ModelSpec.minRAMGB` and `ctxUsable8GB` are the numbers the app checks before downloading and when sizing the KV cache.

## Speed — measured, not quoted

| Where | Model | tok/s |
|---|---|---|
| iPhone 16 Pro (A18 Pro) | Qwen3-1.7B · MLX 4-bit | 41 |
| iPhone 16 Pro | Qwen3-1.7B · GGUF Q4_K_M, llama.cpp Metal | 33 (TTFT 1.6 s) |
| Mac mini M-series | Qwen3-0.6B · GGUF Q4_K_M | 165 |

Single runs from the app's `--selftest` harness, 2 cycles / 1 tool round each. Smaller models are faster; your mileage depends on thermal state.

## Your own runtime

Conform to `Model` and emit `StreamEvent`s in the Bedrock shape Strands consumes — `messageStart · contentBlockStart · contentBlockDelta · contentBlockStop · messageStop · metadata`. `StreamAssembler` turns them into messages; `TokenEstimator` fills in counts when a runtime has no tokenizer.

## Pins

`mlx-swift-lm 3.32.3` (link `MLXLLM` + `MLXLMCommon` only — `MLXHuggingFace` needs iOS 27 types) · `swift-transformers 1.3.4` · llama.cpp `b11401` via `scripts/fetch-llama-xcframework.sh`.
