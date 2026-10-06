#!/usr/bin/env python3
"""Regenerate docs/models.md from the models catalog.

Usage:  python3 docs/gen_models.py [path/to/models.json]
Default catalog: loopl/Resources/models.json (the file bundled in the app),
falling back to ~/.tiny/loopl-20261005/models.catalog.json.
"""
import json, os, sys, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
CANDIDATES = [
    sys.argv[1] if len(sys.argv) > 1 else None,
    os.path.join(HERE, "..", "loopl", "Resources", "models.json"),
    os.path.join(HERE, "..", "App", "Resources", "models.json"),
    os.path.join(HERE, "..", "Sources", "Loopl", "Resources", "models.json"),
    os.path.expanduser("~/.tiny/loopl-20261005/models.catalog.json"),
]
path = next((p for p in CANDIDATES if p and os.path.exists(p)), None)
if not path:
    sys.exit("no catalog found")
doc = json.load(open(path))
models = doc["models"] if isinstance(doc, dict) else doc
default = doc.get("default") if isinstance(doc, dict) else None

def norm(m):
    """Accept both the research catalog schema (camelCase) and the app's models.json (snake_case)."""
    g = lambda *ks, d=None: next((m[k] for k in ks if k in m and m[k] is not None), d)
    params = g("params")
    if params is None and g("params_b") is not None:
        params = f"{g('params_b')}B"
    return {
        "id": m["id"], "repo": g("repo"), "runtime": g("runtime", d="mlx"),
        "displayName": g("displayName", "name", d=m["id"]), "params": params or "—",
        "sizeBytes": g("sizeBytes", "size_bytes", d=0), "ctxMax": g("ctxMax", "ctx_nominal", d=0),
        "ctxRecommended8GB": g("ctxRecommended8GB", "ctx_usable_8gb", d=0), "minRAMGB": g("minRAMGB", "min_ram_gb", d=0),
        "gated": bool(g("gated", d=False)), "toolCalls": g("toolCalls", d=(g("family") in ("hermes","llama3","apple","qwen","mistral"))),
        "family": g("family"), "notes": g("notes"),
    }
models = [norm(m) for m in models]

RUNTIME = {"apple": "Apple FM", "mlx": "MLX", "gguf": "GGUF"}

def gb(b):
    if not b: return "—"
    return f"{b/1e9:.2f} GB" if b >= 1e9 else f"{b/1e6:.0f} MB"

def row(m):
    name = m["displayName"]
    if m.get("repo"):
        name = f"[{name}](https://huggingface.co/{m['repo']})"
    if default and m["id"] == default:
        name += " :material-star:{ title=\"default\" }"
    return "| {} | {} | {} | {} | {:,} | {:,} | {} | {} | {} |".format(
        name, RUNTIME.get(m["runtime"], m["runtime"]), m.get("params", "—"), gb(m.get("sizeBytes")),
        m.get("ctxMax", 0), m.get("ctxRecommended8GB", 0),
        f"{m['minRAMGB']} GB" if m.get("minRAMGB") else "—",
        "yes" if m.get("gated") else "no", "✓" if m.get("toolCalls") else "—")

out = []
out.append('---\ntitle: "Models"\ndescription: "The models the loopl app ships in its catalog, with size, context and whether they call tools. Any public Hugging Face repo works too."\nhide:\n  - navigation\n---\n')
out.append("# Models\n")
out.append("The app's built-in catalog. Every entry is a public Hugging Face repo — no token — including the **loopl** MLX models; "
           "only the loopl GGUF builds (`gated: yes`) are private and need your own token (Settings › Hugging Face). Any other "
           "public MLX or GGUF repo loads the same way. *Usable on 8 GB* is the context that fits beside the weights on an "
           "iPhone 16 Pro; it is the app's default.\n")
COLLECTION = "https://huggingface.co/collections/cagataydev/loopl-on-device-agents-swift-6ac51395b13a9c41d4932eaf"
out.append("## The loopl models\n")
out.append("Qwen3.5 0.8B, 2B and 4B post-tuned on [cagataydev/loopl-train](https://huggingface.co/datasets/cagataydev/loopl-train) (private): "
           "the agent loop and how this runtime behaves, tool calls in both dialects loopl speaks, recovering from a tool error instead "
           "of repeating it, who they are. The vision tower is the base's, kept — the MLX exports read photos; the GGUF exports are text-only. "
           f"They are public, in one place: **[the loopl collection on Hugging Face]({COLLECTION})** — the three MLX 4-bit exports "
           "(what the app downloads) and the three bf16 checkpoints (the base for continual post-tuning with Models › Train your own). "
           "Each card has the scores against the base, the recipe and how to run it in the app, with `mlx_vlm` or from Swift. "
           "The GGUF builds, LoRA adapter and the training dataset stay private.\n")
out.append("| | MLX 4-bit · vision · public | bf16 · post-tuning base · public | GGUF Q4_K_M · text · private |\n|---|---|---|---|")
for size in ("0.8b", "2b", "4b"):
    out.append(f"| loopl {size.upper()} | [loopl-{size}-4bit](https://huggingface.co/cagataydev/loopl-{size}-4bit) "
               f"| [loopl-{size}](https://huggingface.co/cagataydev/loopl-{size}) | loopl-{size}-GGUF (token) |")
out.append("\nIn the app: Models › **loopl models** → download (no account). "
           "On a Mac: `pip install mlx-vlm` then `python -m mlx_vlm.generate --model cagataydev/loopl-2b-4bit --image photo.jpg --prompt \"What is this?\"`.\n")
out.append("## The catalog\n")
out.append("<div class=\"loopl-models-table\" markdown>\n")
out.append("| Model | Runtime | Params | 4-bit size | ctx max | usable on 8 GB | min RAM | gated | tool calls |")
out.append("|---|---|---|---|---:|---:|---|---|:-:|")
order = {"apple": 0, "mlx": 1, "gguf": 2}
for m in sorted(models, key=lambda m: (order.get(m["runtime"], 9), -(m.get("ctxRecommended8GB") or 0), m["displayName"])):
    out.append(row(m))
out.append("\n</div>\n")
out.append("## Notes per model\n")
for m in models:
    if m.get("notes"):
        out.append(f"- **{m['displayName']}** — {m['notes']}")
out.append("")
out.append("## Picking one\n")
out.append("- **Default:** `{}` — the best balance of tool calls, speed and context on an 8 GB phone.".format(default or "qwen3-1.7b-4bit"))
out.append("- **Up to 4B** parameters at 4-bit fit comfortably; 7–8B load but leave little room for context.")
out.append("- **Tool calls** are reliable on Qwen3, Llama 3.2 and Apple's model; Gemma and SmolLM manage one tool, not many.\n")
gen = (doc.get("generatedAt") or doc.get("updated")) if isinstance(doc, dict) else None
out.append(f"<small>Generated by `docs/gen_models.py` from `{os.path.relpath(path, os.path.join(HERE, '..'))}`"
           + (f" (catalog {gen})" if gen else "") + f" on {datetime.date.today().isoformat()}. "
           "Re-run the script after editing the catalog — do not edit this page by hand.</small>")
open(os.path.join(HERE, "models.md"), "w").write("\n".join(out) + "\n")
print(f"wrote docs/models.md ({len(models)} models) from {path}")
