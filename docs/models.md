# Models

What the loopl app ships in its catalog (`models.json`), and what the SDK's `Catalog` exposes. Every MLX entry is an `mlx-community` 4-bit conversion downloaded straight from Hugging Face; none of them is gated. The Apple entry needs no download at all.

!!! tip "How to read *usable context*"
    *ctx max* is the model's `max_position_embeddings`. *usable on 8 GB* is what fits next to the 4-bit weights and the KV cache on an iPhone 16 Pro (8 GB, ~5–6 GB per-app jetsam limit) — the value the app uses as its default context. Bigger phones can raise it in **Agent → Context**.

<div class="loopl-models-table" markdown>

| Model | Runtime | Params | 4-bit size | ctx max | usable on 8 GB | min RAM | gated | tool calls |
|---|---|---|---|---:|---:|---|---|:-:|
| [DeepSeek-R1-Distill-Qwen-1.5B (4-bit)](https://huggingface.co/mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit) | MLX | 1.8B | 1000 MB | 131,072 | 8,192 | 6 GB | no | — |
| [Llama-3.2-1B Instruct (4-bit)](https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit) | MLX | 1.2B | 695 MB | 131,072 | 8,192 | 6 GB | no | ✓ |
| [Llama-3.2-3B Instruct (4-bit)](https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit) | MLX | 3.2B | 1.81 GB | 131,072 | 8,192 | 8 GB | no | ✓ |
| [Phi-4-mini-instruct (4-bit)](https://huggingface.co/mlx-community/Phi-4-mini-instruct-4bit) | MLX | 3.8B | 2.16 GB | 131,072 | 8,192 | 8 GB | no | ✓ |
| [Qwen2.5-1.5B Instruct (4-bit)](https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit) | MLX | 1.5B | 869 MB | 32,768 | 8,192 | 6 GB | no | ✓ |
| [Qwen2.5-3B Instruct (4-bit)](https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit) | MLX | 3.1B | 1.74 GB | 32,768 | 8,192 | 8 GB | no | ✓ |
| [Qwen3-0.6B (4-bit)](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit) | MLX | 0.6B | 335 MB | 40,960 | 8,192 | 6 GB | no | ✓ |
| [Qwen3-1.7B (4-bit)](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) :material-star:{ title="default" } | MLX | 1.7B | 968 MB | 40,960 | 8,192 | 6 GB | no | ✓ |
| [Qwen3-4B (4-bit)](https://huggingface.co/mlx-community/Qwen3-4B-4bit) | MLX | 4.0B | 2.26 GB | 40,960 | 8,192 | 8 GB | no | ✓ |
| [SmolLM3-3B (4-bit)](https://huggingface.co/mlx-community/SmolLM3-3B-4bit) | MLX | 3.1B | 1.73 GB | 65,536 | 8,192 | 8 GB | no | ✓ |
| [gemma-3-1b IT (4-bit)](https://huggingface.co/mlx-community/gemma-3-1b-it-4bit) | MLX | 1.0B | 733 MB | 32,768 | 8,192 | 6 GB | no | — |
| [gemma-3-1b IT-qat (4-bit)](https://huggingface.co/mlx-community/gemma-3-1b-it-qat-4bit) | MLX | 1.0B | 733 MB | 32,768 | 8,192 | 6 GB | no | — |
| [gemma-3-4b IT-qat (4-bit)](https://huggingface.co/mlx-community/gemma-3-4b-it-qat-4bit) | MLX | 4.3B | 3.00 GB | 131,072 | 6,838 | 8 GB | no | — |
| [gemma-3-4b IT (4-bit)](https://huggingface.co/mlx-community/gemma-3-4b-it-4bit) | MLX | 4.3B | 3.40 GB | 131,072 | 5,383 | 12 GB | no | — |
| Apple Intelligence (on-device) | appleFM | 3.0B | — | 4,096 | 4,096 | — | no | — |

</div>

## Notes per model

- **Apple Intelligence (on-device)** — iOS 26+, Apple Intelligence enabled, iPhone 15 Pro or later; zero download; offline; SystemLanguageModel.default.availability
- **Qwen3-0.6B (4-bit)** — 40960 = 32k native; thinking mode on by default (/no_think or enable_thinking=false) loopl passes enable_thinking=false for the agent loop. KV 112 KiB/token → memory-bound ctx ≈39,799 on 8 GB (estimate).
- **Qwen3-1.7B (4-bit)** — 40960 = 32k native; thinking mode on by default (/no_think or enable_thinking=false) loopl passes enable_thinking=false for the agent loop. KV 112 KiB/token → memory-bound ctx ≈34,283 on 8 GB (estimate).
- **Qwen3-4B (4-bit)** — 40960 = 32k native; thinking mode on by default (/no_think or enable_thinking=false) loopl passes enable_thinking=false for the agent loop. KV 144 KiB/token → memory-bound ctx ≈17,883 on 8 GB (estimate).
- **Qwen2.5-1.5B Instruct (4-bit)** — KV 28 KiB/token → memory-bound ctx ≈32,768 on 8 GB (estimate).
- **Qwen2.5-3B Instruct (4-bit)** — KV 36 KiB/token → memory-bound ctx ≈32,768 on 8 GB (estimate).
- **Llama-3.2-1B Instruct (4-bit)** — KV 32 KiB/token → memory-bound ctx ≈128,317 on 8 GB (estimate).
- **Llama-3.2-3B Instruct (4-bit)** — KV 112 KiB/token → memory-bound ctx ≈26,964 on 8 GB (estimate).
- **gemma-3-1b IT (4-bit)** — hybrid local/global attention → real KV below the fp16 formula; template has no tools branch → JSON-in-prompt fallback No tool role in the template — loopl folds tool results into user turns. KV 26 KiB/token → memory-bound ctx ≈32,768 on 8 GB (estimate).
- **gemma-3-4b IT (4-bit)** — hybrid local/global attention → real KV below the fp16 formula; template has no tools branch → JSON-in-prompt fallback No tool role in the template — loopl folds tool results into user turns. KV 136 KiB/token → memory-bound ctx ≈10,766 on 8 GB (estimate).
- **gemma-3-1b IT-qat (4-bit)** — hybrid local/global attention → real KV below the fp16 formula; template has no tools branch → JSON-in-prompt fallback No tool role in the template — loopl folds tool results into user turns. KV 26 KiB/token → memory-bound ctx ≈32,768 on 8 GB (estimate).
- **gemma-3-4b IT-qat (4-bit)** — hybrid local/global attention → real KV below the fp16 formula; template has no tools branch → JSON-in-prompt fallback No tool role in the template — loopl folds tool results into user turns. KV 136 KiB/token → memory-bound ctx ≈13,676 on 8 GB (estimate).
- **Phi-4-mini-instruct (4-bit)** — KV 128 KiB/token → memory-bound ctx ≈20,919 on 8 GB (estimate).
- **SmolLM3-3B (4-bit)** — KV 72 KiB/token → memory-bound ctx ≈42,995 on 8 GB (estimate).
- **DeepSeek-R1-Distill-Qwen-1.5B (4-bit)** — reasoning model, <think> output, no tool template KV 28 KiB/token → memory-bound ctx ≈131,072 on 8 GB (estimate).

## Picking a model

- **Default**: `qwen3-1.7b-4bit` — the best balance of tool-call reliability, speed and context on an 8 GB phone.
- **≤ 4B** parameters at 4-bit fit comfortably; **7B/8B class** models load but leave little room for context — the app warns before downloading them (the catalog's `minRAMGB` vs the device) and keeps the context budget at `ctxUsable8GB`.
- **Tool calls** are proven on the Qwen3 / Qwen2.5 (Hermes format), Llama 3.2 and Apple families. Gemma and SmolLM fall back to plain-JSON parsing — fine for one tool, flaky for many.
- **Context**: the KV cache is the real cost. Doubling context roughly doubles the memory the model needs beyond its weights.

<small>Generated by `docs/gen_models.py` from `loopl/Resources/models.json` (catalog 2026-10-05) on 2026-10-04. Re-run the script after editing the catalog — do not edit this page by hand.</small>
