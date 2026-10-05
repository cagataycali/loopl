---
description: The three on-device runtimes behind loopl's Model protocol — MLX Swift, Apple Foundation Models and GGUF on llama.cpp — compared, with guidance on which to pick.
---

# Runtimes

A runtime is a `Model` implementation (an actor). Three ship in `LooplRuntimes`; the agent loop does not care which.

| | MLX Swift | Apple Foundation Models | GGUF / llama.cpp |
|---|---|---|---|
| Type | `MLXModel` | `AppleFoundationModel` | `GGUFModel` |
| `RuntimeKind` | `.mlx` | `.appleFM` | `.gguf` |
| iOS | 18+ (real device) | 26+ (Apple Intelligence device) | 18+ (device: Metal · simulator: CPU) |
| Models | any public `mlx-community/*-4bit` repo | Apple's ~3B system model | any single-file GGUF (catalog: Q4_K_M) |
| Download | 0.3–2.3 GB per model | **none** | 0.4–2.5 GB |
| Context | nominal 32k–131k; **8k usable** on 8 GB | **4,096** tokens, hard | `n_ctx` = `GenerationParams.contextLength` |
| Tool calls | chat-template `tools:` (Hermes/Qwen, Llama 3) + `ToolCallStreamGate` | specs in instructions, `.generic` family | specs folded into the system prompt + `ToolCallStreamGate` |
| Streaming | token deltas, exact token counts | snapshot partials → deltas, **estimated** token counts | token deltas, exact counts |
| Compute | Metal GPU | Neural Engine (closed) | Metal GPU |
| Offline | yes, once the files are on disk | yes | yes |
| `availability()` | `.ok` | `.ok` or the reason (not eligible / AI off / model not ready / needs iOS 26) | `.ok`; on the simulator *available* with a "CPU only" reason |

## Choosing

- You want *a* model with zero friction on a modern phone → **Apple Foundation Models**. No download, no token, Apple's
  guardrails. Short context, closed weights, no tokenizer (so the context meter shows ≈).
- You want to pick the model, see tok/s, and have 8k+ context → **MLX**. The app's default, `mlx-community/Qwen3-0.6B-4bit`,
  is small enough to download on first launch; `Qwen3-1.7B-4bit` (968 MB) runs ~40–50 tok/s on an A18 Pro.
- You already have GGUF files, want Q4_K_M quantisations, or need a model nobody converted to MLX → **GGUF**. Same
  families as MLX in the catalog (Qwen3 0.6B/1.7B/4B, Llama 3.2 3B, Gemma 3 1B, SmolLM2 1.7B), one file each.

The app's Model list groups rows by runtime and shows `RuntimeAvailability.reason` verbatim when a runtime cannot run on
this device (no Apple Intelligence, iOS version, simulator).

## Why not Core ML / ANE?

The Neural Engine is only reachable through Core ML, which wants static shapes and fp16 and has no good story for the
dynamic int4 KV-cache pattern LLM decoding needs. Apple's own public Core ML LLM artefacts are un-quantised and 12–19 GB.
MediaPipe (Gemma `.task`) and ExecuTorch (`.pte`) both need a per-model export step, which breaks "pick a repo on
Hugging Face and run it". Apple's Foundation Models runtime is the one path that uses the ANE for an LLM, and it is
closed — that is why it is one of the runtimes.
