# MLX Swift

`MLXModel` wraps [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) `3.32.3` (`MLXLLM` +
`MLXLMCommon`) and tokenizes with `swift-transformers` `1.3.4`.

```swift
let model = MLXModel()                                  // RuntimeKind.mlx · availability() == .ok
try await model.load(spec, from: directory) { p in … }  // directory = where HFDownloader put the repo files
```

## What it does for you

- **Load from disk, no network.** `load(spec, from:)` calls `LLMModelFactory.shared.loadContainer(from: directory, …)`.
  A `nil` directory throws `ModelError("<name> is not downloaded")` — downloading is `HFDownloader`'s job
  ([Model protocol → Downloading](../sdk/models.md#downloading)).
- **Memory.** `MLX.GPU.set(cacheLimit: 32 MB)` before load; `unload()` drops the container and `MLX.GPU.clearCache()`.
- **Context.** `GenerationParams.contextLength` becomes `GenerateParameters.maxKVSize` — the KV cache is capped, so an
  over-long conversation degrades instead of jetsamming. The catalog's `ctxUsable8GB` (8,192) is the default on an 8 GB phone.
- **Tool calls.** The tool specs go through the tokenizer's chat template (`applyChatTemplate(messages:tools:additionalContext:)`),
  so Qwen3/Llama 3 see tools exactly the way they were trained. If the template rejects `tools:` (older templates), the
  encoder falls back to a system-prompt listing. The agent's `ToolCallParser` lifts the calls from the text.
- **Thinking models.** `ModelSpec.chatTemplateKwargs` (`enable_thinking: false` for Qwen3) is passed as
  `additionalContext`, so agent runs get `<tool_call>` blocks, not a `<think>` monologue.
- **Metrics.** Real token counts from the tokenizer (`Metrics.estimated == false`), TTFT and tok/s per turn.

## Pins & gotchas

| | |
|---|---|
| `mlx-swift-lm` | `3.32.3` exact; link **only** `MLXLLM` + `MLXLMCommon` — `MLXHuggingFace`'s macros pull `MLXFoundationModels`, which needs iOS 27 types |
| `mlx-swift` | ≥ 0.30.6 — [#462](https://github.com/ml-explore/mlx-swift/issues/462) produced gibberish on iPhone 16 Pro |
| Entitlement | `com.apple.developer.kernel.increased-memory-limit` — [#492](https://github.com/ml-explore/mlx-swift-lm/issues/492) |
| Simulator | no Metal JIT — the `#if` branch that imports MLX only compiles for device builds; use `FakeModel` on the simulator |
| Offline | once the directory is complete **no network call is made**; `HFDownloader` refuses early when `NetworkPolicy.isOffline` |

## Expected speed (iPhone 16 Pro, A18 Pro)

Decode is memory-bandwidth-bound: roughly `bandwidth ÷ weight bytes`.

| Model | 4-bit size | tok/s (approx.) | TTFT @ 1k prompt |
|---|---|---|---|
| Qwen3-0.6B | 335 MB | 80–100 | < 0.3 s |
| Qwen3-1.7B (default) | 968 MB | 40–50 | ~0.5 s |
| Llama-3.2-3B | 1.81 GB | 20–30 | ~1 s |
| Qwen3-4B / Phi-4-mini | 2.2–2.3 GB | 15–20 | ~1.5 s |

Numbers are bandwidth estimates; the app's HUD shows the measured ones.
