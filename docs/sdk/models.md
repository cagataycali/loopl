---
title: "Runtimes"
description: "One Model protocol, three on-device engines: MLX, llama.cpp (GGUF) and Apple Foundation Models. Any public Hugging Face repo."
---

# Runtimes

`Model` is a protocol: `load`, `stream`, `unload`, `updateConfig`. `LooplRuntimes` ships three engines; the agent doesn't care which one it gets.

| | `MLXModel` | `GGUFModel` | `AppleFoundationModel` |
|---|---|---|---|
| Weights | Hugging Face MLX, 4-bit | any `.gguf` (llama.cpp) | Apple's, already on the phone |
| Runs on | device (Metal) | device · simulator on CPU | iOS 26, Apple Intelligence on |
| Download | 0.3–2.3 GB | 0.4–2.5 GB | none |
| Context | 8k on an 8 GB phone | `GenerationParams.contextLength` | 4,096 |
| Images | yes, vision checkpoints | — | — |

Call `availability()` first; it says why an engine can't run here (simulator, iOS version, Apple Intelligence off).

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
    params.contextLength = spec.ctxUsable8GB
    if let t = spec.temperature { params.temperature = t }
    await model.updateConfig(params)
    return model
}

func loadGGUF(_ spec: ModelSpec, dir: URL) async throws -> GGUFModel {
    let model = GGUFModel()
    print(GGUFModel.availability().reason)          // empty on a device; why not, on the simulator
    try await model.load(spec, from: dir) { _ in }
    return model
}
```

`AppleFoundationModel().load(spec, from: nil)` loads nothing — the model is already there.

## Any public model

`HubCatalog` searches Hugging Face anonymously and turns a repo into a `ModelSpec`; `HFDownloader` fetches it, resumably.

```swift
// snippet: compile(wrap)
let hub = HubCatalog()
let hits = try await hub.search("qwen3", kind: .mlx)          // .gguf for GGUF repos
let spec = try await hub.resolve(hits[0].id)                 // runtime, size, context, RAM need
```

`ModelSpec.minRAMGB` and `ctxUsable8GB` are what the app checks before a download. The bundled `Catalog` is listed on [Models](../models.md).

## Speed

| Device | Model | tok/s |
|---|---|---|
| iPhone 16 Pro | Qwen3-1.7B · MLX 4-bit | 41 |
| iPhone 16 Pro | Qwen3-1.7B · GGUF Q4_K_M | 33 |
| Mac mini | Qwen3-0.6B · GGUF Q4_K_M | 165 |

Single runs from the app's self-test. Thermal state matters.

## Apple Foundation Models

Apple's model is prompted for tools in plain prose. A JSON-wrapped reply is unwrapped to its sentence, a call written as text is asked for once more, and after a failed call it may call again with corrected arguments — it reads the `ERROR:` result like any model. Text streams live — a revised snapshot arrives as `textReplace`. Its window is 4,096 tokens; the conversation manager sizes itself to that.

## Your own engine

Conform to `Model` and emit `StreamEvent`s: `messageStart · contentBlockStart · contentBlockDelta · contentBlockStop · messageStop · metadata`. `StreamAssembler` turns them into messages; `TokenEstimator` fills in counts when there is no tokenizer.
