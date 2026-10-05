# Runtimes

A runtime is a `Model` implementation. Three ship in `LooplRuntimes`; the agent loop does not care which.

| | MLX Swift | Apple Foundation Models | GGUF / llama.cpp |
|---|---|---|---|
| Type | `MLXModel` | `AppleFoundationModel` | `GGUFModel` |
| iOS | 18+ (real device) | 26+ (Apple Intelligence device) | 18+ · **v2, stub today** |
| Models | any `mlx-community/*-4bit` on Hugging Face | Apple's ~3B system model | any GGUF (Q4_K_M) |
| Download | 0.3–2.3 GB per model | **none** | 0.4–2.5 GB |
| Context | nominal 32k–131k; **8k usable** on 8 GB | **4,096** tokens, hard | `n_ctx` you choose |
| Tool calls | native parsers (Qwen/Hermes, Llama 3, Mistral, Gemma) + core fallback | native `Tool` protocol | text parser |
| Streaming | token deltas | snapshot partials (accumulated text) | token deltas |
| Compute | Metal GPU | Neural Engine (closed) | Metal GPU |
| Offline | yes, once the files are on disk | yes | yes |
| Status | **shipping** | **shipping** | roadmap |

## Choosing

- You want *a* model with zero friction on a modern phone → **Apple Foundation Models**. No download,
  no token, Apple's guardrails. Short context, closed weights.
- You want to pick the model, see tok/s, and have 8k+ context → **MLX**. The default
  `mlx-community/Qwen3-1.7B-4bit` is 968 MB and ~40–50 tok/s on an A18 Pro.
- You already have GGUF files or need a model nobody converted to MLX → **GGUF**, when v2 lands.

The app lets the user set a **runtime preference**; when the preferred one is unavailable
(no Apple Intelligence, simulator) it falls back and says why.

## Why not Core ML / ANE?

The Neural Engine is only reachable through Core ML, which wants static shapes and fp16 and has no good
story for the dynamic int4 KV-cache pattern LLM decoding needs. Apple's own public Core ML LLM artefacts
are un-quantised and 12–19 GB. MediaPipe (Gemma `.task`) and ExecuTorch (`.pte`) both need a per-model
export step, which breaks "pick a repo on Hugging Face and run it". Details in the research notes in
the repo.
