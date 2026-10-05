# Runtimes

A runtime is a `Model` implementation (an actor). Three ship in `LooplRuntimes`; the agent loop does not care which.

| | MLX Swift | Apple Foundation Models | GGUF / llama.cpp |
|---|---|---|---|
| Type | `MLXModel` | `AppleFoundationModel` | `GGUFModel` |
| `RuntimeKind` | `.mlx` | `.appleFM` | `.gguf` |
| iOS | 18+ (real device) | 26+ (Apple Intelligence device) | **v2 — stub today** |
| Models | any `mlx-community/*-4bit` on Hugging Face | Apple's ~3B system model | any GGUF (Q4_K_M) |
| Download | 0.3–2.3 GB per model | **none** | 0.4–2.5 GB |
| Context | nominal 32k–131k; **8k usable** on 8 GB | **4,096** tokens, hard | `n_ctx` you choose |
| Tool calls | chat-template `tools:` (Hermes/Qwen, Llama 3) + core parser | manual spec in instructions, `.generic` parser | text parser |
| Streaming | token deltas, exact token counts | snapshot partials → deltas, **estimated** token counts | token deltas |
| Compute | Metal GPU | Neural Engine (closed) | Metal GPU |
| Offline | yes, once the files are on disk | yes | yes |
| `availability()` | `.ok` | `.ok` or the reason (not eligible / AI off / model not ready / needs iOS 26) | always unavailable, reason "planned for v2" |

## Choosing

- You want *a* model with zero friction on a modern phone → **Apple Foundation Models**. No download, no token, Apple's
  guardrails. Short context, closed weights, no tokenizer (so the context meter shows ≈).
- You want to pick the model, see tok/s, and have 8k+ context → **MLX**. The default `mlx-community/Qwen3-1.7B-4bit`
  is 968 MB and ~40–50 tok/s on an A18 Pro.
- You already have GGUF files or need a model nobody converted to MLX → **GGUF**, when v2 lands.

The app lets the user set a **runtime preference**; it shows `RuntimeAvailability.reason` verbatim when the preferred
runtime cannot run (no Apple Intelligence, simulator, iOS version).

## Why not Core ML / ANE?

The Neural Engine is only reachable through Core ML, which wants static shapes and fp16 and has no good story for the
dynamic int4 KV-cache pattern LLM decoding needs. Apple's own public Core ML LLM artefacts are un-quantised and 12–19 GB.
MediaPipe (Gemma `.task`) and ExecuTorch (`.pte`) both need a per-model export step, which breaks "pick a repo on
Hugging Face and run it". Apple's Foundation Models runtime is the one path that uses the ANE for an LLM, and it is
closed — that is why it is one of the runtimes.
