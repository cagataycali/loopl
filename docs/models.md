---
title: "Models"
description: "The models the loopl app ships in its catalog, with size, context and whether they call tools. Any public Hugging Face repo works too."
hide:
  - navigation
---

# Models

The app's built-in catalog. Every entry is a public Hugging Face repo — no token — including the **loopl** MLX models; only the loopl GGUF builds (`gated: yes`) are private and need your own token (Settings › Hugging Face). Any other public MLX or GGUF repo loads the same way. *Usable on 8 GB* is the context that fits beside the weights on an iPhone 16 Pro; it is the app's default.

## The loopl models

Qwen3.5 0.8B, 2B and 4B post-tuned on [cagataydev/loopl-train](https://huggingface.co/datasets/cagataydev/loopl-train) (private): the agent loop and how this runtime behaves, tool calls in both dialects loopl speaks, recovering from a tool error instead of repeating it, who they are. The vision tower is the base's, kept — the MLX exports read photos; the GGUF exports are text-only. They are public, in one place: **[the loopl collection on Hugging Face](https://huggingface.co/collections/cagataydev/loopl-on-device-agents-swift-6ac51395b13a9c41d4932eaf)** — the three MLX 4-bit exports (what the app downloads) and the three bf16 checkpoints (the base for continual post-tuning with Models › Train your own). Each card has the scores against the base, the recipe and how to run it in the app, with `mlx_vlm` or from Swift. The GGUF builds, LoRA adapter and the training dataset stay private.

| | MLX 4-bit · vision · public | bf16 · post-tuning base · public | GGUF Q4_K_M · text · private |
|---|---|---|---|
| loopl 0.8B | [loopl-0.8b-4bit](https://huggingface.co/cagataydev/loopl-0.8b-4bit) | [loopl-0.8b](https://huggingface.co/cagataydev/loopl-0.8b) | loopl-0.8b-GGUF (token) |
| loopl 2B | [loopl-2b-4bit](https://huggingface.co/cagataydev/loopl-2b-4bit) | [loopl-2b](https://huggingface.co/cagataydev/loopl-2b) | loopl-2b-GGUF (token) |
| loopl 4B | [loopl-4b-4bit](https://huggingface.co/cagataydev/loopl-4b-4bit) | [loopl-4b](https://huggingface.co/cagataydev/loopl-4b) | loopl-4b-GGUF (token) |

In the app: Models › **loopl models** → download (no account). On a Mac: `pip install mlx-vlm` then `python -m mlx_vlm.generate --model cagataydev/loopl-2b-4bit --image photo.jpg --prompt "What is this?"`.

## The catalog

<div class="loopl-models-table" markdown>

| Model | Runtime | Params | 4-bit size | ctx max | usable on 8 GB | min RAM | gated | tool calls |
|---|---|---|---|---:|---:|---|---|:-:|
| [Qwen3.5 0.8B](https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit) | MLX | 0.8B | 652 MB | 262,144 | 16,384 | 2 GB | no | ✓ |
| [loopl 0.8B](https://huggingface.co/cagataydev/loopl-0.8b-4bit) | MLX | 0.8B | 652 MB | 262,144 | 16,384 | 2 GB | no | ✓ |
| [Qwen3-VL 2B](https://huggingface.co/mlx-community/Qwen3-VL-2B-Instruct-4bit) | MLX | 2.0B | 1.80 GB | 262,144 | 12,288 | 3 GB | no | ✓ |
| [Qwen3-VL 2B Thinking](https://huggingface.co/mlx-community/Qwen3-VL-2B-Thinking-4bit) | MLX | 2.0B | 1.80 GB | 262,144 | 12,288 | 3 GB | no | ✓ |
| [Qwen3.5 2B](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit) | MLX | 2.0B | 1.75 GB | 262,144 | 12,288 | 3 GB | no | ✓ |
| [loopl 2B](https://huggingface.co/cagataydev/loopl-2b-4bit) | MLX | 2.0B | 1.75 GB | 262,144 | 12,288 | 3 GB | no | ✓ |
| [DeepSeek-R1-Distill-Qwen-1.5B (4-bit)](https://huggingface.co/mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit) | MLX | 1.8B | 1000 MB | 131,072 | 8,192 | 6 GB | no | — |
| [Llama-3.2-1B Instruct (4-bit)](https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit) | MLX | 1.2B | 695 MB | 131,072 | 8,192 | 6 GB | no | ✓ |
| [Llama-3.2-3B Instruct (4-bit)](https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit) | MLX | 3.2B | 1.81 GB | 131,072 | 8,192 | 8 GB | no | ✓ |
| [Phi-4-mini-instruct (4-bit)](https://huggingface.co/mlx-community/Phi-4-mini-instruct-4bit) | MLX | 3.8B | 2.16 GB | 131,072 | 8,192 | 8 GB | no | ✓ |
| [Qwen3-0.6B (4-bit)](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit) :material-star:{ title="default" } | MLX | 0.6B | 335 MB | 40,960 | 8,192 | 6 GB | no | ✓ |
| [Qwen3-1.7B (4-bit)](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) | MLX | 1.7B | 968 MB | 40,960 | 8,192 | 6 GB | no | ✓ |
| [Qwen3-4B (4-bit)](https://huggingface.co/mlx-community/Qwen3-4B-4bit) | MLX | 4.0B | 2.26 GB | 40,960 | 8,192 | 8 GB | no | ✓ |
| [Qwen3-VL 4B](https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit) | MLX | 4.0B | 3.11 GB | 262,144 | 8,192 | 5 GB | no | ✓ |
| [Qwen3-VL 4B Thinking](https://huggingface.co/mlx-community/Qwen3-VL-4B-Thinking-4bit) | MLX | 4.0B | 3.11 GB | 262,144 | 8,192 | 5 GB | no | ✓ |
| [SmolLM3-3B (4-bit)](https://huggingface.co/mlx-community/SmolLM3-3B-4bit) | MLX | 3.1B | 1.73 GB | 65,536 | 8,192 | 8 GB | no | ✓ |
| [gemma-3-1b IT (4-bit)](https://huggingface.co/mlx-community/gemma-3-1b-it-4bit) | MLX | 1.0B | 733 MB | 32,768 | 8,192 | 6 GB | no | — |
| [gemma-3-1b IT-qat (4-bit)](https://huggingface.co/mlx-community/gemma-3-1b-it-qat-4bit) | MLX | 1.0B | 733 MB | 32,768 | 8,192 | 6 GB | no | — |
| [loopl 4B](https://huggingface.co/cagataydev/loopl-4b-4bit) | MLX | 4.0B | 3.06 GB | 262,144 | 8,192 | 6 GB | no | ✓ |
| [gemma-3-4b IT-qat (4-bit)](https://huggingface.co/mlx-community/gemma-3-4b-it-qat-4bit) | MLX | 4.3B | 3.00 GB | 131,072 | 6,838 | 8 GB | no | — |
| [gemma-3-4b IT (4-bit)](https://huggingface.co/mlx-community/gemma-3-4b-it-4bit) | MLX | 4.3B | 3.40 GB | 131,072 | 5,383 | 12 GB | no | — |
| [Gemma 3 1B IT · Q4_K_M (llama.cpp)](https://huggingface.co/unsloth/gemma-3-1b-it-GGUF) | GGUF | 1.0B | 806 MB | 32,768 | 8,192 | 6 GB | no | — |
| [Llama 3.2 3B Instruct · Q4_K_M (llama.cpp)](https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF) | GGUF | 3.2B | 2.02 GB | 131,072 | 8,192 | 8 GB | no | ✓ |
| [Qwen3 0.6B · Q4_K_M (llama.cpp)](https://huggingface.co/unsloth/Qwen3-0.6B-GGUF) | GGUF | 0.6B | 397 MB | 40,960 | 8,192 | 3 GB | no | ✓ |
| [Qwen3 1.7B · Q4_K_M (llama.cpp)](https://huggingface.co/unsloth/Qwen3-1.7B-GGUF) | GGUF | 1.7B | 1.11 GB | 40,960 | 8,192 | 6 GB | no | ✓ |
| [Qwen3 4B · Q4_K_M (llama.cpp)](https://huggingface.co/unsloth/Qwen3-4B-GGUF) | GGUF | 4.0B | 2.50 GB | 40,960 | 8,192 | 8 GB | no | ✓ |
| [SmolLM2 1.7B Instruct · Q4_K_M (llama.cpp)](https://huggingface.co/bartowski/SmolLM2-1.7B-Instruct-GGUF) | GGUF | 1.7B | 1.06 GB | 8,192 | 8,192 | 6 GB | no | — |
| [loopl 0.8B · Q4_K_M (llama.cpp)](https://huggingface.co/cagataydev/loopl-0.8b-GGUF) | GGUF | 0.8B | 529 MB | 262,144 | 8,192 | 3 GB | yes | ✓ |
| [loopl 2B · Q4_K_M (llama.cpp)](https://huggingface.co/cagataydev/loopl-2b-GGUF) | GGUF | 2.0B | 1.27 GB | 262,144 | 8,192 | 4 GB | yes | ✓ |
| [loopl 4B · Q4_K_M (llama.cpp)](https://huggingface.co/cagataydev/loopl-4b-GGUF) | GGUF | 4.0B | 2.71 GB | 262,144 | 4,096 | 6 GB | yes | ✓ |
| Apple Intelligence (on-device) | appleFM | 3.0B | — | 4,096 | 4,096 | — | no | — |

</div>

## Notes per model

- **Qwen3-0.6B (4-bit)** — 40960 = 32k native; thinking mode on by default (/no_think or enable_thinking=false) loopl passes enable_thinking=false for the agent loop. KV 112 KiB/token → memory-bound ctx ≈39,799 on 8 GB (estimate).
- **Apple Intelligence (on-device)** — iOS 26+, Apple Intelligence enabled, iPhone 15 Pro or later; zero download; offline; SystemLanguageModel.default.availability
- **Qwen3-1.7B (4-bit)** — 40960 = 32k native; thinking mode on by default (/no_think or enable_thinking=false) loopl passes enable_thinking=false for the agent loop. KV 112 KiB/token → memory-bound ctx ≈34,283 on 8 GB (estimate).
- **Qwen3-4B (4-bit)** — 40960 = 32k native; thinking mode on by default (/no_think or enable_thinking=false) loopl passes enable_thinking=false for the agent loop. KV 144 KiB/token → memory-bound ctx ≈17,883 on 8 GB (estimate).
- **Qwen3.5 0.8B** — Sees pictures. Smallest Qwen3.5 (image-text-to-text), 4-bit MLX. Proven on Mac: image → description + tool call.
- **Qwen3.5 2B** — Sees pictures. Qwen3.5 2B, 4-bit MLX — the sweet spot for photos + tools on an 8 GB phone.
- **Qwen3-VL 2B** — Sees pictures. Qwen3-VL 2B Instruct, 4-bit MLX.
- **Qwen3-VL 4B** — Sees pictures. Qwen3-VL 4B Instruct, 4-bit MLX — best vision quality that fits an 8 GB phone.
- **Qwen3-VL 2B Thinking** — Sees pictures and thinks before answering. Qwen3-VL 2B Thinking, 4-bit MLX. The template always opens a <think> block (no enable_thinking switch) — loopl shows the reasoning, then the answer. Slower than Instruct: expect a few hundred reasoning tokens per turn.
- **Qwen3-VL 4B Thinking** — Sees pictures and thinks before answering. Qwen3-VL 4B Thinking, 4-bit MLX — best vision reasoning that fits an 8 GB phone. The template always opens a <think> block (no enable_thinking switch) — loopl shows the reasoning, then the answer. Slower than Instruct.
- **Llama-3.2-1B Instruct (4-bit)** — KV 32 KiB/token → memory-bound ctx ≈128,317 on 8 GB (estimate).
- **Llama-3.2-3B Instruct (4-bit)** — KV 112 KiB/token → memory-bound ctx ≈26,964 on 8 GB (estimate).
- **gemma-3-1b IT (4-bit)** — hybrid local/global attention → real KV below the fp16 formula; template has no tools branch → JSON-in-prompt fallback No tool role in the template — loopl folds tool results into user turns. KV 26 KiB/token → memory-bound ctx ≈32,768 on 8 GB (estimate).
- **gemma-3-1b IT-qat (4-bit)** — hybrid local/global attention → real KV below the fp16 formula; template has no tools branch → JSON-in-prompt fallback No tool role in the template — loopl folds tool results into user turns. KV 26 KiB/token → memory-bound ctx ≈32,768 on 8 GB (estimate).
- **gemma-3-4b IT (4-bit)** — hybrid local/global attention → real KV below the fp16 formula; template has no tools branch → JSON-in-prompt fallback No tool role in the template — loopl folds tool results into user turns. KV 136 KiB/token → memory-bound ctx ≈10,766 on 8 GB (estimate).
- **gemma-3-4b IT-qat (4-bit)** — hybrid local/global attention → real KV below the fp16 formula; template has no tools branch → JSON-in-prompt fallback No tool role in the template — loopl folds tool results into user turns. KV 136 KiB/token → memory-bound ctx ≈13,676 on 8 GB (estimate).
- **Phi-4-mini-instruct (4-bit)** — KV 128 KiB/token → memory-bound ctx ≈20,919 on 8 GB (estimate).
- **SmolLM3-3B (4-bit)** — KV 72 KiB/token → memory-bound ctx ≈42,995 on 8 GB (estimate).
- **DeepSeek-R1-Distill-Qwen-1.5B (4-bit)** — reasoning model, <think> output, no tool template KV 28 KiB/token → memory-bound ctx ≈131,072 on 8 GB (estimate).
- **Qwen3 0.6B · Q4_K_M (llama.cpp)** — Single-file GGUF; built-in chat template with tools.
- **Qwen3 1.7B · Q4_K_M (llama.cpp)** — Single-file GGUF; built-in chat template with tools.
- **Qwen3 4B · Q4_K_M (llama.cpp)** — Single-file GGUF.
- **Llama 3.2 3B Instruct · Q4_K_M (llama.cpp)** — Public mirror (no licence gate).
- **Gemma 3 1B IT · Q4_K_M (llama.cpp)** — No tool template — manual JSON prompting.
- **SmolLM2 1.7B Instruct · Q4_K_M (llama.cpp)** — Small and fast; manual JSON prompting.
- **loopl 0.8B** — loopl v1.1 — Qwen3.5-0.8B post-tuned by Cagatay Cali on cagataydev/loopl-train (agent loop, tools, robots, identity + who Cagatay Cali is and his projects; trained on loopl-train v2.1 rev db6fa452). Vision kept (mlx_vlm export: vision_tower + preprocessor_config, same layout as the mlx-community base). Public — no token. bf16 base for Train your own: cagataydev/loopl-0.8b.
- **loopl 0.8B · Q4_K_M (llama.cpp)** — loopl v1.1 GGUF (text-only, llama.cpp b11401 --no-mtp; trained on loopl-train v2.1 rev db6fa452 — identity/bio family, file cards, repair trajectories). Private: needs the user's HF token.
- **loopl 2B** — loopl v1.1 — Qwen3.5-2B post-tuned by Cagatay Cali on cagataydev/loopl-train (agent loop, tools, robots, identity + who Cagatay Cali is and his projects; trained on loopl-train v2.1 rev db6fa452). Vision kept (mlx_vlm export: vision_tower + preprocessor_config, same layout as the mlx-community base). Public — no token. bf16 base for Train your own: cagataydev/loopl-2b.
- **loopl 2B · Q4_K_M (llama.cpp)** — loopl v1.1 GGUF (text-only, llama.cpp b11401 --no-mtp; trained on loopl-train v2.1 rev db6fa452 — identity/bio family, file cards, repair trajectories). Private: needs the user's HF token.
- **loopl 4B** — loopl v1.1 — Qwen3.5-4B LoRA r64 post-tuned by Cagatay Cali on cagataydev/loopl-train. Vision kept (mlx_vlm export: vision_tower + preprocessor_config, same layout as the mlx-community base). Public — no token. bf16 base for Train your own: cagataydev/loopl-4b.
- **loopl 4B · Q4_K_M (llama.cpp)** — loopl v1.1 GGUF (text-only, llama.cpp b11401 --no-mtp; trained on loopl-train v2.1 rev db6fa452 — identity/bio family, file cards, repair trajectories). Private: needs the user's HF token.

## Picking one

- **Default:** `qwen3-0.6b-4bit` — the best balance of tool calls, speed and context on an 8 GB phone.
- **Up to 4B** parameters at 4-bit fit comfortably; 7–8B load but leave little room for context.
- **Tool calls** are reliable on Qwen3, Llama 3.2 and Apple's model; Gemma and SmolLM manage one tool, not many.

<small>Generated by `docs/gen_models.py` from `App/Resources/models.json` (catalog 2026-10-07) on 2026-10-06. Re-run the script after editing the catalog — do not edit this page by hand.</small>
