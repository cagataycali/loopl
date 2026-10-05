# MLX Swift

`MLXModel` wraps [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) and downloads
weights from Hugging Face with `swift-huggingface`.

```swift
let model = MLXModel("mlx-community/Qwen3-1.7B-4bit",
                     hfToken: nil,                       // or Keychain-backed, for gated repos
                     contextLength: 8192,                // nil = catalog's usable default for this device
                     kvBits: 8)
try await model.load { progress in print(progress.fractionCompleted) }
```

## What it does for you

- **Cache location.** Weights live in `Application Support/loopl/models/<org>--<name>/` (not
  `Library/Caches`, which iOS purges under pressure) with `isExcludedFromBackup = true` so iCloud never
  uploads gigabytes.
- **Resume.** Partial files resume with `Range:` on relaunch; the app shows the aggregate progress.
- **Memory.** `GPU.set(cacheLimit: 32 MB)` before load; `os_proc_available_memory()` compared with
  `sizeBytes + kvBytesPerToken × contextLength` → `ModelError.insufficientMemory` instead of a jetsam.
- **Context.** A rotating `KVCacheConfiguration.Capacity(maxTokens:)` so an over-long conversation degrades
  instead of crashing; the usable default is `min(memoryBound / 2, 8192, model max)`.
- **Tool calls.** mlx-swift-lm 3.x parses Llama 3, Qwen/Hermes, Mistral and Gemma tool-call formats
  natively and emits `ModelEvent.toolUse`; the core `ToolCallParser` stays as the fallback (and as what
  unit tests pin).
- **Thinking models.** Qwen3 defaults to a `<think>` monologue; the catalog sets
  `templateKwargs: ["enable_thinking": false]` for agent runs. You can turn it back on per prompt.

## Pins & gotchas

| | |
|---|---|
| `mlx-swift-lm` | 3.32.3 with trait `FoundationModelsIntegration` **off** (needs the iOS 27 SDK); or pin 2.31.3 |
| `mlx-swift` | ≥ 0.30.6 — [#462](https://github.com/ml-explore/mlx-swift/issues/462) produced gibberish on iPhone 16 Pro |
| Entitlement | `com.apple.developer.kernel.increased-memory-limit` — [#492](https://github.com/ml-explore/mlx-swift-lm/issues/492) |
| Simulator | no Metal JIT → `ModelError.unsupportedEnvironment("simulator")` |
| Offline | once the snapshot resolves locally, **no network call is made**; the app never calls the Hub listing when `Reachability.isOnline == false` |

## Expected speed (iPhone 16 Pro, A18 Pro)

Decode is memory-bandwidth-bound: roughly `bandwidth ÷ weight bytes`.

| Model | 4-bit size | tok/s (approx.) | TTFT @ 1k prompt |
|---|---|---|---|
| Qwen3-0.6B | 335 MB | 80–100 | < 0.3 s |
| Qwen3-1.7B (default) | 968 MB | 40–50 | ~0.5 s |
| Llama-3.2-3B | 1.81 GB | 20–30 | ~1 s |
| Qwen3-4B / Phi-4-mini | 2.2–2.3 GB | 15–20 | ~1.5 s |

Numbers are estimates from bandwidth; the app's `TokenMeter` shows the real ones.
