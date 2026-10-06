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

`ModelSpec.minRAMGB` and `ctxUsable8GB` are what the app checks before a download.

## Private repos

Hand both a token provider and the same calls reach the user's private repos. `HFTokenProvider` is a closure, read per request, so signing out takes effect at once; `HFAccount` keeps one token in the Keychain.

```swift
// snippet: compile(wrap)
let account = HFAccount.shared                                   // try account.setToken("hf_…") once
let hub = HubCatalog(token: account.provider)
let downloader = HFDownloader(token: account.provider)
let mine = try await hub.mine(author: account.username ?? "me")  // MLX + GGUF, private ones included
_ = (mine, downloader)
```

Without a token both stay anonymous. A redirect to the CDN drops the authorization header. The bundled `Catalog` is listed on [Models](../models.md).

A repo exported with transformers 5 names a `tokenizer_class` the Swift tokenizer has never heard of (`Qwen3_5Tokenizer`). The MLX runtime loads it anyway — the BPE in `tokenizer.json` is the same — and when a load still fails on those files, `HFDownloader.repairSmallFiles` refreshes only the small files whose git blob hash differs from the Hub's; the weights stay. `TokenizerFiles.audit(dir)` tells you beforehand.

**Vision is read from the files, not the name.** `HubCatalog.isVision` trusts the Hub's `image-text-to-text` tag, then the
repo's file list (an image-processor config means a tower; a vision `model_type` without one is a text-only export), and
`spec(for:config:)` lets `config.json`'s `vision_config` decide once it has been read. After a download the app re-reads the
local `config.json` (`LocalModelFiles.hasVisionTower`), so the composer's photo button follows the weights on the device.

## loopl's own models

`cagataydev/loopl-*` (and anything you train from the app) carry their identity in the weights — loopl-train bakes it in.
The SDK and the app add nothing in front of your system prompt: `Agent(systemPrompt:)` sends exactly what you give it,
to every model.

## Where the weights live

A model directory can sit on an external drive. `ModelLocation` is `.internalStorage` or a folder on a volume the user picked (`StorageBookmark`, a security-scoped bookmark); `StorageManifest` records which model lives where. `ExternalStorage.move(directory:to:)` copies, checks sizes and SHA-256, then deletes the source — and rolls back on failure. `ExternalStorage.ensureSpace(need:at:volumeName:)` refuses a download that would leave less than 200 MB.

## See what the model saw

`MLXModel.setTrace` reports each generation as a `GenerationTrace`: the prompt after the chat template (special tokens kept), the raw output before any parsing, and the tool calls the runtime's own detector accepted or rejected.

```swift
// snippet: compile(wrap,runtimes)
let model = MLXModel()
await model.setTrace { t in print(t.promptTokens, t.nativeToolCalls, t.raw.prefix(80)) }
```

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
