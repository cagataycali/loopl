# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "torch>=2.6",
#   "transformers>=5.3,<6",
#   "trl>=1.0,<2",
#   "peft>=0.18",
#   "accelerate>=1.3",
#   "datasets>=3.2",
#   "huggingface_hub>=1.0",
#   "jinja2>=3.1",
#   "flash-linear-attention[cuda]>=0.5; sys_platform == 'linux'",
# ]
# ///
"""loopl_sft.py — post-tune a Qwen3.5 model from YOUR loopl conversations, end to end, in ONE Hugging Face Job.

This is the single-file training script the loopl iOS app ships (App/Resources/train/loopl_sft.py). The app uploads it
into the user's own private dataset repo and starts a Job that runs it — nothing of loopl's has to be public and the only
credential involved is the user's own HF token (HF_TOKEN secret). It runs equally well by hand:

    hf jobs uv run --flavor a10g-small --timeout 2h -s HF_TOKEN train/loopl_sft.py -- \
        --dataset <user>/<conversations-dataset> --base 0.8b --out <user>/loopl-mine-0.8b

What it does (stages are printed as `[loopl] stage=<name>` lines so a UI can show live progress):
  discover  read every *.jsonl in the dataset (or `train.jsonl` + `eval.jsonl` when present), validate the loopl schema
            ({"messages":[…], "tools":[…]}), de-duplicate, optional denylist / PII guard, deterministic held-out split
  render    every sample in BOTH tool dialects loopl uses at inference (native Qwen3.5 <function=…> XML for the MLX path,
            hermes JSON <tool_call> for the GGUF path), empty <think> block like enable_thinking=false, assistant-only loss
  train     TRL SFT — full fine-tune for ≤ 2B (when the GPU has room) or LoRA r64 (4B / small GPUs); 2 epochs, evaluate every
            epoch, keep the checkpoint with the lowest eval loss (TRAIN lane: 3 epochs over-fit at ~900 samples)
  eval      held-out eval loss base vs tuned + generation probes (tool-call validity, prose answers) → scorecard.json
  push      merged weights + scorecard + model card → <out>  (private by default)
  mlx       mlx_lm.convert 4-bit (CPU, isolated uv env)      → <out>-4bit   (what the loopl app loads on iPhone/iPad/Mac)
  gguf      llama.cpp <tag> convert (--no-mtp: transformers drops Qwen3.5's MTP head) + Q4_K_M → <out>-GGUF
  done      `[loopl] done {…json…}` with every repo id, counts and timings

Data format (loopl-train schema, see schema/conversation.schema.json): one JSON object per line,
  {"messages":[{"role":"system|user|assistant|tool","content":str|parts, "tool_calls":[…], "tool_call_id":…,"name":…}],
   "tools":[{"type":"function","function":{"name","description","parameters"}}], "source":{…}}
Images (content parts) are reduced to their text — vision tuning is a separate path.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_VERSION = "1.0.3"
LLAMA_TAG_DEFAULT = "b11401"  # the llama.cpp build the loopl app vendors (scripts/fetch-llama-xcframework.sh)

BASES = {"0.8b": "Qwen/Qwen3.5-0.8B", "2b": "Qwen/Qwen3.5-2B", "4b": "Qwen/Qwen3.5-4B"}
# measured by the TRAIN lane (train/FULL-RUNS.md): full FT beats LoRA 3× on knowledge for the same data; 4B full FT wants an H200
RECIPES = {
    "0.8b": {"full_lr": 2e-5, "lora_lr": 1e-4, "batch": 2, "accum": 8},
    "2b": {"full_lr": 1.5e-5, "lora_lr": 1e-4, "batch": 2, "accum": 8},
    "4b": {"full_lr": 1e-5, "lora_lr": 1e-4, "batch": 1, "accum": 16},
}

HERMES_BLOCK = (
    "# Tools\n\n"
    "You may call one or more functions to assist with the user query.\n\n"
    "You are provided with function signatures within <tools></tools> XML tags:\n"
    "<tools>\n{specs}\n</tools>\n\n"
    "For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:\n"
    "<tool_call>\n{{\"name\": <function-name>, \"arguments\": <args-json-object>}}\n</tool_call>\n"
    "After the tool results arrive, answer the user in plain text."
)

T0 = time.time()


def stage(name: str, **kw):
    extra = (" " + json.dumps(kw, ensure_ascii=False)) if kw else ""
    print(f"[loopl] stage={name} t={time.time() - T0:.0f}s{extra}", flush=True)


def log(msg: str):
    print(f"[loopl] {msg}", flush=True)


# ----------------------------------------------------------------------------- data helpers (mirrors train/sft.py + Swift PromptBuilder)
def compact(v) -> str:
    """Swift JSONValue.compact: sorted keys, no spaces, ints without .0."""
    if isinstance(v, bool) or v is None:
        return json.dumps(v)
    if isinstance(v, float) and v == int(v) and abs(v) < 1e15:
        return str(int(v))
    if isinstance(v, (int, float, str)):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ",".join(compact(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ",".join(f"{json.dumps(k, ensure_ascii=False)}:{compact(v[k])}" for k in sorted(v)) + "}"
    return json.dumps(v, ensure_ascii=False)


def _args_dict(a):
    if isinstance(a, str):
        try:
            return json.loads(a)
        except json.JSONDecodeError:
            return {"_raw": a}
    return a or {}


_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]{0,63}$")
_SCHEMA_VALIDATOR = None  # set by --schema: a jsonschema Draft validator over schema/conversation.schema.json


def validate(sample: dict) -> str | None:
    """Return a reason when the sample is not a loopl conversation, else None.

    The rules are the ones in loopl-train `schema/conversation.schema.json` (shared with the app's ConversationExport):
    roles ∈ {system,user,assistant,tool}; a tool turn carries `tool_call_id` + string `content`; only assistant turns carry
    `tool_calls`, each `{id, function:{name, arguments}}` with a well-formed name. `--schema <file>` enforces the full JSON
    Schema with `jsonschema` instead (strict: `id`/`family` become required, which app shards and loopl-train both set).
    """
    if _SCHEMA_VALIDATOR is not None:
        err = next(iter(_SCHEMA_VALIDATOR.iter_errors(sample)), None)
        return None if err is None else f"schema: {'/'.join(str(x) for x in err.absolute_path) or '$'}: {err.message[:120]}"
    if not isinstance(sample, dict):
        return "not an object"
    msgs = sample.get("messages")
    if not isinstance(msgs, list) or len(msgs) < 2:
        return "messages missing or shorter than 2"
    roles = {"system", "user", "assistant", "tool"}
    for i, m in enumerate(msgs):
        if not isinstance(m, dict) or m.get("role") not in roles:
            return f"message {i}: bad role"
        role = m["role"]
        if role != "assistant" and m.get("tool_calls"):
            return f"message {i}: {role} turn carries tool_calls"
        if role == "tool" and (not m.get("tool_call_id") or not isinstance(m.get("content"), str)):
            return f"message {i}: tool turn needs tool_call_id and string content"
        if role == "system" and not (isinstance(m.get("content"), str) and m["content"]):
            return f"message {i}: empty system turn"
        if role == "assistant" and not (m.get("content") or m.get("tool_calls")):
            return f"message {i}: empty assistant turn"
        for tc in m.get("tool_calls") or []:
            fn = tc.get("function", tc) if isinstance(tc, dict) else None
            if not fn or not fn.get("name"):
                return f"message {i}: tool call without a name"
            if not _NAME_RE.match(str(fn["name"])):
                return f"message {i}: bad tool name {fn['name']!r}"
            if "arguments" not in fn:
                return f"message {i}: tool call {fn['name']} without arguments"
    if not any(m["role"] == "assistant" for m in msgs):
        return "no assistant turn"
    tools = sample.get("tools")
    if tools is not None and not isinstance(tools, (list, str)):
        return "tools is not a list"
    return None


def load_schema(path: str) -> None:
    """--schema: validate every row against the shared JSON Schema (jsonschema is pulled in by uv only when asked)."""
    global _SCHEMA_VALIDATOR
    import importlib
    try:
        jsonschema = importlib.import_module("jsonschema")
    except ImportError:
        subprocess.run([sys.executable, "-m", "pip", "install", "-q", "jsonschema>=4"], check=True)
        jsonschema = importlib.import_module("jsonschema")
    with open(path, encoding="utf-8") as f:
        schema = json.load(f)
    _SCHEMA_VALIDATOR = jsonschema.Draft202012Validator(schema)
    log(f"schema: {path} ({schema.get('$id') or schema.get('title') or 'conversation'})")


def normalize(sample: dict) -> tuple[list[dict], list[dict]]:
    """Return (messages, tools) with tool_calls.function.arguments as dicts and content as str."""
    tools = sample.get("tools") or []
    if isinstance(tools, str):
        tools = json.loads(tools)
    msgs = []
    for m in sample["messages"]:
        m = dict(m)
        c = m.get("content")
        if isinstance(c, list):  # content parts → text only
            c = "".join(p.get("text", "") for p in c if isinstance(p, dict) and p.get("type", "text") == "text")
        m["content"] = c if c is not None else ""
        if m.get("tool_calls"):
            tcs = []
            for tc in m["tool_calls"]:
                fn = tc.get("function", tc)
                tcs.append({"id": tc.get("id") or f"call_{len(tcs)}", "type": "function",
                            "function": {"name": fn["name"], "arguments": _args_dict(fn.get("arguments"))}})
            m["tool_calls"] = tcs
        msgs.append(m)
    sys_override = sample.get("system")
    if sys_override and (not msgs or msgs[0]["role"] != "system"):
        msgs.insert(0, {"role": "system", "content": sys_override})
    return msgs, tools


def to_loopl_dialect(messages: list[dict], tools: list[dict]) -> list[dict]:
    """PromptBuilder.toolSystemPrompt(.hermes) + foldToolMessages, as the app's GGUF path does."""
    out: list[dict] = []
    base = messages[0]["content"] if messages and messages[0]["role"] == "system" else None
    body = messages[1:] if base is not None else messages
    if tools:
        specs = "\n".join(compact(t) for t in tools)
        sys_text = (base + "\n\n" if base else "") + HERMES_BLOCK.format(specs=specs)
        out.append({"role": "system", "content": sys_text})
    elif base:
        out.append({"role": "system", "content": base})
    pending: dict[str, str] = {}
    for m in body:
        role = m["role"]
        if role == "tool":
            name = m.get("name") or pending.get(m.get("tool_call_id", ""), "tool")
            line = f'<tool_response name="{name}" id="{m.get("tool_call_id", "")}">\n{m["content"]}\n</tool_response>'
            if out and out[-1]["role"] == "user":
                out[-1]["content"] += "\n" + line
            else:
                out.append({"role": "user", "content": line})
        elif role == "assistant" and m.get("tool_calls"):
            for tc in m["tool_calls"]:
                pending[tc["id"]] = tc["function"]["name"]
            rendered = "\n".join(
                f'<tool_call>\n{{"name": "{tc["function"]["name"]}", "arguments": {compact(tc["function"]["arguments"])}}}\n</tool_call>'
                for tc in m["tool_calls"])
            text = m.get("content") or ""
            out.append({"role": "assistant", "content": (text + "\n" if text else "") + rendered})
        else:
            out.append({"role": role, "content": m.get("content") or ""})
    return out


EMPTY_THINK = "<think>\n\n</think>\n\n"
_HEADER_NO_THINK = re.compile(r"<\|im_start\|>assistant\n(?!<think>)")
ASSISTANT_HEADER = "<|im_start|>assistant\n"
END = "<|im_end|>"


def render(tokenizer, messages, tools, dialect: str, add_generation_prompt=False) -> str:
    if dialect == "native":
        text = tokenizer.apply_chat_template(messages, tools=tools or None, tokenize=False,
                                             add_generation_prompt=add_generation_prompt)
    else:
        text = tokenizer.apply_chat_template(to_loopl_dialect(messages, tools), tokenize=False,
                                             add_generation_prompt=add_generation_prompt)
    # loopl generates with enable_thinking=false → every assistant turn starts with the empty think block
    return _HEADER_NO_THINK.sub("<|im_start|>assistant\n" + EMPTY_THINK, text)


def assistant_spans(text: str) -> list[tuple[int, int]]:
    spans, i = [], 0
    while True:
        s = text.find(ASSISTANT_HEADER, i)
        if s < 0:
            break
        body = s + len(ASSISTANT_HEADER)
        e = text.find(END, body)
        if e < 0:
            spans.append((body, len(text)))
            break
        spans.append((body, e + len(END)))  # include <|im_end|> so the model learns to stop
        i = e + len(END)
    return spans


def assistant_weights(messages: list[dict]) -> list[int]:
    """Per assistant turn, in order: 0 when the message carries `weight: 0` (kept in the prompt, excluded from the loss)."""
    return [0 if m.get("weight", 1) == 0 else 1 for m in messages if m.get("role") == "assistant"]


def tokenize_with_mask(tokenizer, text: str, max_length: int, weights: list[int] | None = None) -> dict | None:
    enc = tokenizer(text, add_special_tokens=False, return_offsets_mapping=True, truncation=True, max_length=max_length)
    spans = assistant_spans(text)
    if weights and len(weights) == len(spans):
        spans = [sp for sp, w in zip(spans, weights) if w]
    mask = [0 if a == b else (1 if any(a >= s and b <= e for s, e in spans) else 0) for (a, b) in enc["offset_mapping"]]
    if 1 not in mask:
        return None
    return {"input_ids": enc["input_ids"], "assistant_masks": mask}


# ----------------------------------------------------------------------------- guard (optional)
PII_PATTERNS = [
    (re.compile(r"hf_[A-Za-z0-9]{20,}"), "<hf_token>"),
    (re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"), "Bearer <token>"),
    (re.compile(r"sk-[A-Za-z0-9]{20,}"), "<api_key>"),
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "<email>"),
    # phone numbers: +, digits, spaces, dots, dashes, parens — but not ISO dates / times / plain integers
    (re.compile(r"(?<![\w:-])(?:\+\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)[\s.-]?)?\d{3}[\s.-]\d{3}[\s.-]?\d{2,4}(?![\w:-])"), "<phone>"),
]


def scrub_pii(text: str) -> tuple[str, int]:
    n = 0
    for rx, rep in PII_PATTERNS:
        text, k = rx.subn(rep, text)
        n += k
    return text, n


def apply_guard(sample: dict, denylist: list[str], pii: bool) -> tuple[dict | None, int]:
    """Drop the sample when a denylisted term appears; scrub PII in every text field. Returns (sample|None, pii_hits)."""
    blob = json.dumps(sample, ensure_ascii=False)
    low = blob.lower()
    for term in denylist:
        if term and term.lower() in low:
            return None, 0
    if not pii:
        return sample, 0
    hits = 0

    def walk(v):
        nonlocal hits
        if isinstance(v, str):
            s, k = scrub_pii(v)
            hits += k
            return s
        if isinstance(v, list):
            return [walk(x) for x in v]
        if isinstance(v, dict):
            return {k: walk(x) for k, x in v.items()}
        return v
    return walk(sample), hits


# ----------------------------------------------------------------------------- discovery
def _read_jsonl(path: Path):
    with open(path) as fh:
        for ln, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError as e:
                log(f"skip {path.name}:{ln}: {e}")


def discover(dataset: str, revision: str | None, token: str | None, eval_frac: float, limit: int | None,
             denylist: list[str], pii: bool) -> tuple[list[dict], list[dict], dict]:
    """Load the dataset (Hub repo or local path/file), validate, guard, de-duplicate and split."""
    files: list[Path] = []
    p = Path(dataset)
    if p.exists():
        files = [p] if p.is_file() else sorted(x for x in p.rglob("*.jsonl"))
        source = str(p)
    else:
        from huggingface_hub import HfApi, hf_hub_download
        api = HfApi(token=token)
        info = api.dataset_info(dataset, revision=revision, token=token)
        names = [s.rfilename for s in info.siblings]
        if revision is None:
            revision = info.sha
        jsonl = [n for n in names if n.endswith(".jsonl") and not n.startswith(("train/", "eval/strands_quiz"))]
        if "train.jsonl" in jsonl:  # loopl-train layout: explicit splits at the repo root
            wanted = ["train.jsonl"] + (["eval.jsonl"] if "eval.jsonl" in jsonl else [])
        else:
            wanted = jsonl
        for n in wanted:
            files.append(Path(hf_hub_download(dataset, n, repo_type="dataset", token=token, revision=revision)))
        source = f"{dataset}@{revision}"
    if not files:
        raise SystemExit(f"no .jsonl files found in {dataset}")
    stats = {"files": [f.name for f in files], "revision": revision, "read": 0, "invalid": 0, "duplicates": 0,
             "denylisted": 0, "pii_scrubbed": 0}
    explicit_eval = [f for f in files if f.name == "eval.jsonl"]
    seen: set[str] = set()
    train, held = [], []
    for f in files:
        is_eval = f in explicit_eval
        for s in _read_jsonl(f):
            stats["read"] += 1
            why = validate(s)
            if why:
                stats["invalid"] += 1
                if stats["invalid"] <= 5:
                    log(f"invalid sample ({f.name}): {why}")
                continue
            key = hashlib.sha1(json.dumps(s.get("messages"), sort_keys=True, ensure_ascii=False).encode()).hexdigest()
            if key in seen:
                stats["duplicates"] += 1
                continue
            seen.add(key)
            s, hits = apply_guard(s, denylist, pii)
            if s is None:
                stats["denylisted"] += 1
                continue
            stats["pii_scrubbed"] += hits
            s["_key"] = key
            (held if is_eval else train).append(s)
    if limit:
        train = train[:limit]
    if not explicit_eval and eval_frac > 0 and len(train) >= 10:
        # deterministic split on the content hash so re-runs on a grown dataset keep earlier held-out rows held out
        cut = int(eval_frac * 0xFFFF)
        held = [s for s in train if int(s["_key"][:4], 16) < cut]
        train = [s for s in train if int(s["_key"][:4], 16) >= cut]
        if not held:
            held, train = train[-1:], train[:-1]
    stats.update({"train": len(train), "eval": len(held), "source": source})
    stage("discover", **{k: v for k, v in stats.items() if k != "files"})
    if not train:
        raise SystemExit("no trainable conversations after validation")
    return train, held, stats


def build_rows(tokenizer, samples: list[dict], fmt: str, max_length: int, oversample_tools: int = 1):
    from datasets import Dataset
    rows, stats = [], {"rendered": 0, "no_assistant": 0, "render_error": 0, "truncated": 0, "with_tools": 0}
    dialects = ["native", "loopl"] if fmt == "both" else [fmt]
    for sample in samples:
        try:
            messages, tools = normalize(sample)
        except Exception as e:  # noqa: BLE001
            stats["render_error"] += 1
            if stats["render_error"] <= 3:
                log(f"normalize error: {e}")
            continue
        if tools:
            stats["with_tools"] += 1
        for d in dialects:
            try:
                text = render(tokenizer, messages, tools, d)
            except Exception as e:  # noqa: BLE001
                stats["render_error"] += 1
                if stats["render_error"] <= 3:
                    log(f"render error ({d}): {e}")
                continue
            row = tokenize_with_mask(tokenizer, text, max_length, assistant_weights(messages))
            if row is None:
                stats["no_assistant"] += 1
                continue
            if len(row["input_ids"]) >= max_length:
                stats["truncated"] += 1
            reps = oversample_tools if tools else 1
            rows.extend([dict(row)] * reps)
            stats["rendered"] += reps
            if not tools and fmt == "both":
                break  # identical text in both dialects — keep one copy
    if not rows:
        raise SystemExit("no trainable rows")
    return Dataset.from_list(rows).shuffle(seed=42), stats


# ----------------------------------------------------------------------------- generation probes → scorecard
_NATIVE_CALL = re.compile(r"<function=([A-Za-z0-9_.-]+)>")
_HERMES_CALL = re.compile(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", re.S)


def parse_calls(text: str) -> list[str]:
    names = _NATIVE_CALL.findall(text)
    for raw in _HERMES_CALL.findall(text):
        try:
            obj = json.loads(raw)
            if isinstance(obj, dict) and obj.get("name"):
                names.append(str(obj["name"]))
        except json.JSONDecodeError:
            names.append("<malformed>")
    return names


def probe(model, tokenizer, samples: list[dict], n: int, max_new: int = 160, device=None) -> dict:
    """Greedy-generate the LAST assistant turn of up to n held-out conversations, in both dialects, and score it."""
    import torch
    res = {"probed": 0, "tool_turns": 0, "tool_name_match": 0, "tool_call_emitted": 0, "prose_turns": 0,
           "prose_kept_prose": 0, "malformed_calls": 0, "examples": []}
    for sample in samples[:n]:
        messages, tools = normalize(sample)
        tool_idx = [i for i, m in enumerate(messages) if m["role"] == "assistant" and m.get("tool_calls")]
        idx = tool_idx[0] if tool_idx else max(i for i, m in enumerate(messages) if m["role"] == "assistant")
        gold = messages[idx]
        ctx = messages[:idx]
        if ctx[-1]["role"] not in ("user", "tool"):
            continue
        gold_names = [tc["function"]["name"] for tc in gold.get("tool_calls") or []]
        for d in (["native", "loopl"] if tools else ["native"]):
            try:
                prompt = render(tokenizer, ctx, tools, d, add_generation_prompt=True)
                if not prompt.endswith(EMPTY_THINK):
                    prompt += EMPTY_THINK
                ids = tokenizer(prompt, return_tensors="pt", add_special_tokens=False).input_ids
                if ids.shape[1] > 6000:
                    continue
                ids = ids.to(device or model.device)
                with torch.no_grad():
                    out = model.generate(ids, max_new_tokens=max_new, do_sample=False, pad_token_id=tokenizer.pad_token_id)
                text = tokenizer.decode(out[0, ids.shape[1]:], skip_special_tokens=False).split(END)[0]
            except Exception as e:  # noqa: BLE001
                log(f"probe error ({d}): {e}")
                continue
            res["probed"] += 1
            names = parse_calls(text)
            res["malformed_calls"] += names.count("<malformed>")
            if gold_names:
                res["tool_turns"] += 1
                if names:
                    res["tool_call_emitted"] += 1
                if set(gold_names) & set(names):
                    res["tool_name_match"] += 1
            else:
                res["prose_turns"] += 1
                if not names:
                    res["prose_kept_prose"] += 1
            if len(res["examples"]) < 6:
                res["examples"].append({"dialect": d, "user": (ctx[-1].get("content") or "")[:200],
                                        "gold_tools": gold_names, "gold": (gold.get("content") or "")[:200],
                                        "generated": text[:400]})
    return res


# ----------------------------------------------------------------------------- conversions (isolated uv envs, CPU)
def run(cmd: list[str], env: dict | None = None, cwd: str | None = None, timeout: int = 3600):
    log("+ " + " ".join(cmd))
    subprocess.run(cmd, check=True, env=env, cwd=cwd, timeout=timeout)


def convert_mlx(merged_dir: Path, out_dir: Path, bits: int, group: int) -> None:
    extra = "cpu" if platform.system() == "Linux" else ""
    spec = f"mlx-lm[{extra}]>=0.32" if extra else "mlx-lm>=0.32"
    shutil.rmtree(out_dir, ignore_errors=True)
    run(["uv", "run", "--no-project", "--python", "3.12", "--with", spec, "--with", "transformers>=5.7,<6",
         "python", "-m", "mlx_lm", "convert", "--hf-path", str(merged_dir), "--mlx-path", str(out_dir),
         "-q", "--q-bits", str(bits), "--q-group-size", str(group)])


# ----------------------------------------------------------------------------- app-loadable tokenizer files
# transformers 5 writes `tokenizer_class: "Qwen3_5Tokenizer"` (+ a `backend` key, no vocab.json, the chat template only
# inside the python class). The loopl app tokenizes with swift-transformers, whose table has Qwen2Tokenizer but no
# Qwen3_5Tokenizer → "Qwen3_5Tokenizer is not supported" on the phone AFTER the weights downloaded (owner, 2026-10-06).
# So every export gets the tokenizer files of the mlx-community 4-bit base of the same size — the files every stock loopl
# model already loads with — after asserting the vocabulary is identical, and APP_TOKENIZER_CHECK gates the push.
APP_TOKENIZER_CLASS = "Qwen2Tokenizer"
MLX_BASES = {"0.8b": "mlx-community/Qwen3.5-0.8B-4bit", "2b": "mlx-community/Qwen3.5-2B-4bit", "4b": "mlx-community/Qwen3.5-4B-4bit"}
# swift-transformers 1.3.4 TokenizerModel.knownTokenizers
SWIFT_KNOWN_TOKENIZERS = {"BertTokenizer", "CodeGenTokenizer", "CodeLlamaTokenizer", "CohereTokenizer", "DistilbertTokenizer",
                          "DistilBertTokenizer", "FalconTokenizer", "GemmaTokenizer", "GPT2Tokenizer", "LlamaTokenizer",
                          "RobertaTokenizer", "T5Tokenizer", "TokenizersBackend", "PreTrainedTokenizer", "Qwen2Tokenizer",
                          "WhisperTokenizer", "XLMRobertaTokenizer", "Xlm-RobertaTokenizer"}


def mlx_base_for(base: str) -> str | None:
    m = re.search(r"(0\.8|2|4)B", base, re.I)
    return MLX_BASES.get(m.group(1).lower() + "b") if m else None


def normalize_tokenizer_files(out_dir: Path, base_repo: str, token: str | None) -> list[str]:
    """Replace out_dir's tokenizer files with base_repo's (tokenizer.json, chat_template.jinja, vocab.json, merges.txt) and
    rewrite tokenizer_config.json with tokenizer_class Qwen2Tokenizer and no `backend`. Refuses if the vocabulary differs."""
    from huggingface_hub import hf_hub_download
    from huggingface_hub.errors import EntryNotFoundError

    def base(name):
        try:
            return Path(hf_hub_download(base_repo, name, token=token)).read_text()
        except EntryNotFoundError:
            return None

    cur = json.loads((out_dir / "tokenizer.json").read_text())
    bas_text = base("tokenizer.json")
    bas = json.loads(bas_text)
    for key in ("vocab", "merges"):
        if cur["model"].get(key) != bas["model"].get(key):
            raise RuntimeError(f"tokenizer.json model.{key} differs from {base_repo}: vocabulary changed, refusing to swap tokenizer files")
    if cur.get("added_tokens") != bas.get("added_tokens"):
        raise RuntimeError(f"tokenizer.json added_tokens differ from {base_repo}")
    changed: list[str] = []
    if (out_dir / "tokenizer.json").read_text() != bas_text:
        (out_dir / "tokenizer.json").write_text(bas_text); changed.append("tokenizer.json")
    cfg_path = out_dir / "tokenizer_config.json"
    cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
    base_cfg = json.loads(base("tokenizer_config.json") or "{}")
    new = dict(cfg) or dict(base_cfg)
    new["tokenizer_class"] = APP_TOKENIZER_CLASS
    new.pop("backend", None)
    for k in ("eos_token", "pad_token", "bos_token", "model_max_length", "added_tokens_decoder"):
        if k not in new and k in base_cfg:
            new[k] = base_cfg[k]
    if new != cfg:
        cfg_path.write_text(json.dumps(new, indent=2, ensure_ascii=False) + "\n"); changed.append("tokenizer_config.json")
    if not (out_dir / "chat_template.jinja").exists():
        template = cfg.get("chat_template") if isinstance(cfg.get("chat_template"), str) else None
        template = template or base("chat_template.jinja") or (base_cfg.get("chat_template") if isinstance(base_cfg.get("chat_template"), str) else None)
        if not template:
            raise RuntimeError("no chat template in the export or the base")
        (out_dir / "chat_template.jinja").write_text(template); changed.append("chat_template.jinja")
    for name in ("vocab.json", "merges.txt"):
        if not (out_dir / name).exists():
            text = base(name)
            if text is not None:
                (out_dir / name).write_text(text); changed.append(name)
    return changed


def check_app_loadable(out_dir: Path) -> list[str]:
    """What the loopl app does at load, as a list of failures (empty = loadable). Mirrors train/check_mlx_repo.py."""
    fails: list[str] = []
    cfg = json.loads((out_dir / "config.json").read_text()) if (out_dir / "config.json").exists() else None
    if not cfg or not cfg.get("model_type"):
        fails.append("config.json missing or without model_type")
    tc = json.loads((out_dir / "tokenizer_config.json").read_text()) if (out_dir / "tokenizer_config.json").exists() else {}
    cls = tc.get("tokenizer_class") or ""
    if cls.replace("Fast", "") not in SWIFT_KNOWN_TOKENIZERS:
        fails.append(f"tokenizer_class {cls!r} is unknown to swift-transformers ('{cls} is not supported' on iOS)")
    if not (out_dir / "tokenizer.json").exists():
        fails.append("tokenizer.json missing")
    template = (out_dir / "chat_template.jinja").read_text() if (out_dir / "chat_template.jinja").exists() else tc.get("chat_template")
    if not isinstance(template, str) or not template:
        fails.append("no chat template (chat_template.jinja / tokenizer_config.chat_template)")
    elif "tools" not in template:
        fails.append("chat template never mentions `tools`")
    return fails


def make_app_loadable(out_dir: Path, base: str, token: str | None, what: str) -> None:
    mlx_base = mlx_base_for(base)
    if mlx_base:
        changed = normalize_tokenizer_files(out_dir, mlx_base, token)
        log(f"{what}: tokenizer files normalised from {mlx_base} ({', '.join(changed) or 'already clean'})")
    else:
        log(f"{what}: no mlx-community base known for {base} — tokenizer files left as exported")
    fails = check_app_loadable(out_dir)
    if fails:
        raise RuntimeError(f"{what} would not load in the loopl app: " + "; ".join(fails))
    log(f"{what}: app-loadable ✓ (tokenizer_class {APP_TOKENIZER_CLASS}, chat template present)")


def convert_gguf(merged_dir: Path, work: Path, name: str, tag: str, quant: str) -> Path:
    llama = work / "llama.cpp"
    if not llama.exists():
        run(["git", "clone", "--depth", "1", "--branch", tag, "https://github.com/ggml-org/llama.cpp", str(llama)])
    bf16 = work / f"{name}-bf16.gguf"
    # a merged checkpoint has no mtp.* tensors (transformers drops the draft head) → --no-mtp, else the GGUF has a phantom block
    has_mtp = False
    for st in merged_dir.glob("*.safetensors"):
        from safetensors import safe_open
        with safe_open(str(st), "pt") as f:
            has_mtp = has_mtp or any(".mtp." in k or k.startswith("mtp.") for k in f.keys())
    mtp = [] if has_mtp else ["--no-mtp"]
    log(f"MTP tensors present: {has_mtp} → {'keep' if has_mtp else '--no-mtp'}")
    # The tag's requirements file pins transformers 4.57, which does not know `Qwen3_5Tokenizer` (job 6ac4711f) → use the same
    # transformers major as training; `gguf` comes from the tag's own gguf-py (the converter puts it on sys.path). torch/transformers
    # resolve to the versions already in uv's cache from the training env, so this costs seconds, not a second download.
    import importlib.metadata as md
    pins = [f"torch=={md.version('torch')}", f"transformers=={md.version('transformers')}", "numpy", "sentencepiece", "pyyaml", "tqdm",
            "protobuf<5", "safetensors"]
    run(["uv", "run", "--no-project", "--python", "3.12", *sum((["--with", p] for p in pins), []),
         "python", str(llama / "convert_hf_to_gguf.py"), str(merged_dir), "--outtype", "bf16", "--outfile", str(bf16), *mtp],
        timeout=5400)
    arch = "arm64" if platform.machine() in ("aarch64", "arm64") else "x64"
    tarball = work / f"llama-{tag}-bin-ubuntu-{arch}.tar.gz"
    if not tarball.exists():
        run(["curl", "-fsSL", "-o", str(tarball),
             f"https://github.com/ggml-org/llama.cpp/releases/download/{tag}/llama-{tag}-bin-ubuntu-{arch}.tar.gz"])
    bindir = work / "llama-bin"
    bindir.mkdir(exist_ok=True)
    run(["tar", "-xzf", str(tarball), "-C", str(bindir)])
    qbin = next(bindir.glob("**/llama-quantize"))
    out = work / f"{name}-{quant}.gguf"
    env = dict(os.environ, LD_LIBRARY_PATH=f"{qbin.parent}:{os.environ.get('LD_LIBRARY_PATH', '')}")
    run([str(qbin), str(bf16), str(out), quant], env=env)
    bf16.unlink(missing_ok=True)
    return out


# ----------------------------------------------------------------------------- cards
def model_card(a, s: dict, kind: str, parent: str | None = None) -> str:
    n = s["data"]["train"] + s["data"]["eval"]
    name = (parent or a.out).split("/")[-1]
    extra = {"merged": "", "mlx": f"\n\nMLX **{a.q_bits}-bit** (group {a.q_group}) conversion of `{parent}` — load it in the loopl app (Models › Mine).",
             "gguf": f"\n\nGGUF **{a.gguf_quant}** of `{parent}`, llama.cpp **{a.llama_tag}** (the build the loopl app vendors)."}[kind]
    lib = {"merged": "transformers", "mlx": "mlx", "gguf": "gguf"}[kind]
    method = "full fine-tune" if s["method"] == "full" else f"LoRA r={a.lora_r} α={a.lora_alpha} → merged"
    sc = s.get("scorecard") or {}
    return f"""---
base_model: {a.base}
library_name: {lib}
license: apache-2.0
tags: [loopl, post-tuned, sft, trl, on-device, qwen3_5{', mlx' if kind == 'mlx' else ''}{', gguf, llama.cpp' if kind == 'gguf' else ''}]
language: [en]
---

# {name}

Post-tuned with **[loopl](https://loopl.dev)** from **{n} conversations** (`{a.dataset}`{'@' + s['data']['revision'][:8] if s['data'].get('revision') else ''}).
Base `{a.base}` · {method} · {a.epochs:g} epochs, best-eval-loss checkpoint · assistant-only loss · both loopl tool dialects
(native Qwen3.5 `<function=…>` and hermes JSON `<tool_call>`) · `enable_thinking=false`-style empty think blocks.{extra}

| | |
|---|---|
| eval loss base → tuned | {sc.get('eval_loss_base', 'n/a')} → {sc.get('eval_loss_tuned', 'n/a')} ({s['data']['eval']} held-out conversations) |
| tool-call probes | name match {sc.get('tool_name_match', 'n/a')} / {sc.get('tool_turns', 'n/a')} turns · prose stayed prose {sc.get('prose_kept_prose', 'n/a')} / {sc.get('prose_turns', 'n/a')} |
| rows / tokens | {s['rows']} · {s['tokens']:,} (max_length {a.max_length}) |
| job | {s.get('job_id') or 'local'} · {s['wall_s']} s · loopl_sft.py {SCRIPT_VERSION} |

Artifacts: `{a.out}` (merged, transformers) · `{a.out}-4bit` (MLX) · `{a.out}-GGUF` (Q4_K_M). Full numbers in `scorecard.json`.
Made by the loopl app's Train screen — your conversations, your model, your Hugging Face account.
"""


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", default=None, help="HF dataset repo (user/name) or a local .jsonl / directory (required unless --from-merged)")
    ap.add_argument("--revision", default=None, help="dataset revision to pin (default: current sha, recorded)")
    ap.add_argument("--base", default="0.8b", help="0.8b | 2b | 4b or any HF model repo")
    ap.add_argument("--out", required=True, help="HF model repo for the merged model, e.g. me/loopl-mine-0.8b")
    ap.add_argument("--epochs", type=float, default=2.0)
    ap.add_argument("--method", choices=["auto", "full", "lora"], default="auto",
                    help="auto = full fine-tune for ≤ 2B when the GPU has ≥ 40 GB, else LoRA r64")
    ap.add_argument("--lr", type=float, default=None)
    ap.add_argument("--lora-r", type=int, default=64)
    ap.add_argument("--lora-alpha", type=int, default=128)
    ap.add_argument("--batch", type=int, default=None)
    ap.add_argument("--grad-accum", type=int, default=None)
    ap.add_argument("--max-length", type=int, default=4096)
    ap.add_argument("--format", choices=["both", "native", "loopl"], default="both")
    ap.add_argument("--schema", default=None, help="path to schema/conversation.schema.json → strict jsonschema validation of every row")
    ap.add_argument("--oversample-tools", type=int, default=1, help="repeat tool conversations N× (fights dialect bleed)")
    ap.add_argument("--eval-frac", type=float, default=0.1, help="held-out share when the dataset has no eval.jsonl")
    ap.add_argument("--probes", type=int, default=24, help="held-out conversations to generate for the scorecard")
    ap.add_argument("--limit", type=int, default=None, help="use only the first N conversations (smoke runs)")
    ap.add_argument("--denylist", default="", help="comma list of terms: a conversation containing one is dropped")
    ap.add_argument("--pii", action="store_true", help="scrub emails / phone numbers / API tokens from every text field")
    ap.add_argument("--public", action="store_true", help="create the output repos public (default private)")
    ap.add_argument("--skip-mlx", action="store_true")
    ap.add_argument("--skip-gguf", action="store_true")
    ap.add_argument("--q-bits", type=int, default=4)
    ap.add_argument("--q-group", type=int, default=64)
    ap.add_argument("--gguf-quant", default="Q4_K_M")
    ap.add_argument("--llama-tag", default=os.environ.get("LLAMA_TAG", LLAMA_TAG_DEFAULT))
    ap.add_argument("--work", default=os.environ.get("WORK_DIR", "/tmp/loopl-sft"))
    ap.add_argument("--from-merged", default=None, metavar="REPO",
                    help="skip training: download this merged model repo and only run the eval-less push/MLX/GGUF stages (re-export)")
    ap.add_argument("--no-push", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="discover + render + tokenize only (no model, no GPU)")
    ap.add_argument("--seed", type=int, default=42)
    a = ap.parse_args()

    token = os.environ.get("HF_TOKEN")
    if a.schema:
        load_schema(a.schema)
    if not a.dataset and not a.from_merged:
        ap.error("--dataset is required (or --from-merged REPO)")
    size = a.base.lower() if a.base.lower() in BASES else None
    if size:
        a.base = BASES[size]
    recipe = RECIPES.get(size or "0.8b")
    if a.batch is None:
        a.batch = recipe["batch"]
    if a.grad_accum is None:
        a.grad_accum = recipe["accum"]
    denylist = [t.strip() for t in a.denylist.split(",") if t.strip()]
    work = Path(a.work)
    work.mkdir(parents=True, exist_ok=True)
    log(f"loopl_sft.py {SCRIPT_VERSION} · base {a.base} · dataset {a.dataset} · out {a.out} · python {sys.version.split()[0]}")

    if a.from_merged:
        return reexport(a, token, work)

    train_s, eval_s, dstats = discover(a.dataset, a.revision, token, a.eval_frac, a.limit, denylist, a.pii)

    stage("render")
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(a.base, token=token)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    ds, rstats = build_rows(tok, train_s, a.format, a.max_length, a.oversample_tools)
    lens = [len(r) for r in ds["input_ids"]]
    log(f"train rows={len(ds)} tokens mean={sum(lens)/len(lens):.0f} max={max(lens)} sum={sum(lens)} stats={json.dumps(rstats)}")
    eval_ds = None
    if eval_s:
        try:
            eval_ds, _ = build_rows(tok, eval_s, a.format, a.max_length)
            log(f"eval rows={len(eval_ds)}")
        except SystemExit:
            eval_ds = None
    steps = int(len(ds) * a.epochs / (a.batch * a.grad_accum)) + 1
    log(f"planned optimizer steps ≈ {steps}")

    if a.dry_run:
        for r in list(ds)[:2]:
            ids, m = r["input_ids"], r["assistant_masks"]
            print(f"\n===== tokens={len(ids)} assistant_tokens={sum(m)} =====")
            print(tok.decode(ids))
            print("----- LOSS TOKENS -----")
            print(tok.decode([i for i, b in zip(ids, m) if b]))
        print(json.dumps({"dry_run": True, "train": len(train_s), "eval": len(eval_s), "rows": len(ds), "steps": steps,
                          "tokens": sum(lens), "data": dstats, "render": rstats}, indent=1))
        return

    import torch
    from peft import LoraConfig
    from transformers import AutoModelForCausalLM, AutoModelForImageTextToText
    from trl import SFTConfig, SFTTrainer

    try:
        import fla  # noqa: F401
        log("flash-linear-attention: available")
    except Exception as e:  # noqa: BLE001
        log(f"flash-linear-attention: not usable → torch fallback for Gated-DeltaNet layers ({e})")
    cuda = torch.cuda.is_available()
    gpu_gb = torch.cuda.get_device_properties(0).total_memory / 1e9 if cuda else 0
    dtype = torch.bfloat16 if cuda else torch.float32
    params_b = {"0.8b": 0.9, "2b": 2.3, "4b": 4.7}.get(size or "", 0)
    method = a.method
    if method == "auto":
        method = "full" if (params_b and params_b <= 2.5 and gpu_gb >= 40) else "lora"
    lr = a.lr or (recipe["full_lr"] if method == "full" else recipe["lora_lr"])
    log(f"gpu={gpu_gb:.0f} GB method={method} lr={lr} batch={a.batch}x{a.grad_accum} epochs={a.epochs}")
    stage("train", method=method, steps=steps, rows=len(ds))

    try:
        model = AutoModelForImageTextToText.from_pretrained(a.base, dtype=dtype, token=token)
        kind = "image-text-to-text"
    except Exception as e:  # noqa: BLE001
        log(f"AutoModelForImageTextToText failed ({e}) → AutoModelForCausalLM")
        model = AutoModelForCausalLM.from_pretrained(a.base, dtype=dtype, token=token)
        kind = "causal-lm"
    log(f"loaded {a.base} as {kind} dtype {dtype}")
    model.config.use_cache = False

    peft_config, pattern = None, None
    if method == "full":
        for n, p_ in model.named_parameters():  # vision tower frozen — text-only tuning
            if ".visual." in n or n.startswith("model.visual") or ".vision" in n:
                p_.requires_grad_(False)
    else:
        names = [n for n, _ in model.named_modules()]
        lm_prefix = "language_model" if any(".language_model." in n for n in names) else None
        proj = r"(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj|in_proj_qkvz|in_proj_ba|in_proj_qkv|in_proj_z|in_proj_b|in_proj_a|out_proj)"
        pattern = (rf".*\.{lm_prefix}\..*\.{proj}" if lm_prefix else rf".*\.{proj}")
        matched = [n for n in names if re.fullmatch(pattern, n)]
        log(f"LoRA targets: {len(matched)} modules")
        if not matched:
            raise SystemExit("LoRA regex matched nothing — inspect module names")
        peft_config = LoraConfig(r=a.lora_r, lora_alpha=a.lora_alpha, lora_dropout=0.05, target_modules=pattern, task_type="CAUSAL_LM")

    cfg = SFTConfig(
        output_dir=str(work / "ckpt"),
        num_train_epochs=a.epochs,
        per_device_train_batch_size=a.batch, gradient_accumulation_steps=a.grad_accum,
        per_device_eval_batch_size=max(1, a.batch),
        learning_rate=lr, lr_scheduler_type="cosine", warmup_steps=0.03,  # float < 1 = ratio (transformers 5)
        bf16=dtype == torch.bfloat16, logging_steps=5,
        save_strategy="epoch" if eval_ds is not None else "no", save_total_limit=1,
        load_best_model_at_end=eval_ds is not None, metric_for_best_model="eval_loss" if eval_ds is not None else None,
        greater_is_better=False, eval_strategy="epoch" if eval_ds is not None else "no",
        gradient_checkpointing=True, gradient_checkpointing_kwargs={"use_reentrant": False},
        max_length=a.max_length, packing=False,  # Gated-DeltaNet state has no packing boundary
        completion_only_loss=False,  # assistant_masks provided by us
        dataset_kwargs={"skip_prepare_dataset": False}, remove_unused_columns=True, report_to=[], seed=a.seed,
    )
    trainer = SFTTrainer(model=model, args=cfg, train_dataset=ds, eval_dataset=eval_ds, processing_class=tok, peft_config=peft_config)
    scorecard: dict = {"script": SCRIPT_VERSION, "base": a.base, "dataset": a.dataset, "revision": dstats.get("revision"),
                       "method": method, "epochs": a.epochs, "train_conversations": len(train_s), "eval_conversations": len(eval_s)}
    if eval_ds is not None:
        base_eval = trainer.evaluate()
        scorecard["eval_loss_base"] = round(base_eval.get("eval_loss", float("nan")), 4)
        log(f"eval loss BASE = {scorecard['eval_loss_base']}")
    result = trainer.train()
    metrics = dict(result.metrics)
    if eval_ds is not None:
        metrics.update(trainer.evaluate())
        scorecard["eval_loss_tuned"] = round(metrics.get("eval_loss", float("nan")), 4)
        scorecard["eval_history"] = [{k: round(v, 4) if isinstance(v, float) else v for k, v in h.items() if k in ("epoch", "eval_loss")}
                                     for h in trainer.state.log_history if "eval_loss" in h]
        scorecard["best_checkpoint"] = trainer.state.best_model_checkpoint
    scorecard["train_loss"] = round(metrics.get("train_loss", float("nan")), 4)
    log(f"train metrics: {json.dumps({k: v for k, v in metrics.items() if isinstance(v, (int, float))})}")

    stage("merge")
    merged_dir = work / "merged"
    shutil.rmtree(merged_dir, ignore_errors=True)
    merged_dir.mkdir(parents=True)
    merged = trainer.model.merge_and_unload() if peft_config is not None else trainer.model
    merged.config.use_cache = True
    if hasattr(merged, "gradient_checkpointing_disable"):
        merged.gradient_checkpointing_disable()
    merged.save_pretrained(str(merged_dir), safe_serialization=True)
    tok.save_pretrained(str(merged_dir))
    cfg_path = merged_dir / "config.json"
    cfg_json = json.loads(cfg_path.read_text())
    for node in (cfg_json, cfg_json.get("text_config") or {}):
        if node.get("mtp_num_hidden_layers"):
            node["mtp_num_hidden_layers"] = 0  # the MTP draft head is not in the merged weights
    cfg_path.write_text(json.dumps(cfg_json, indent=2))
    from huggingface_hub import HfApi, hf_hub_download
    for f in ("preprocessor_config.json", "video_preprocessor_config.json", "chat_template.jinja", "generation_config.json"):
        try:
            src = hf_hub_download(a.base, f, token=token)
            if not (merged_dir / f).exists():
                shutil.copy(src, merged_dir / f)
        except Exception:  # noqa: BLE001
            pass

    stage("eval", probes=min(a.probes, len(eval_s)))
    if eval_s and a.probes > 0:
        merged.eval()
        try:
            scorecard.update(probe(merged, tok, eval_s, a.probes))
        except Exception as e:  # noqa: BLE001
            log(f"probes failed: {e}")
    if "tool_turns" in scorecard and scorecard["tool_turns"]:
        scorecard["tool_name_match_rate"] = round(scorecard["tool_name_match"] / scorecard["tool_turns"], 3)
    if cuda:
        del trainer
        torch.cuda.empty_cache()

    summary = {"base": a.base, "dataset": a.dataset, "method": method, "lr": lr, "epochs": a.epochs, "rows": len(ds),
               "tokens": sum(lens), "max_length": a.max_length, "batch": a.batch, "grad_accum": a.grad_accum,
               "lora": None if method == "full" else {"r": a.lora_r, "alpha": a.lora_alpha, "target_regex": pattern},
               "data": dstats, "render": rstats, "metrics": {k: v for k, v in metrics.items() if isinstance(v, (int, float))},
               "scorecard": scorecard, "wall_s": round(time.time() - T0),
               "versions": {k: __import__(k).__version__ for k in ("transformers", "trl", "peft", "torch")},
               "job_id": os.environ.get("JOB_ID") or os.environ.get("HF_JOB_ID"), "script": SCRIPT_VERSION}
    (merged_dir / "train_summary.json").write_text(json.dumps(summary, indent=1))
    (merged_dir / "scorecard.json").write_text(json.dumps(scorecard, indent=1))
    (merged_dir / "README.md").write_text(model_card(a, summary, "merged"))
    log("scorecard: " + json.dumps({k: v for k, v in scorecard.items() if k != "examples"}))

    api = HfApi(token=token)
    make_app_loadable(merged_dir, a.base, token, "merged")
    if not a.no_push:
        stage("push", repo=a.out)
        api.create_repo(a.out, private=not a.public, exist_ok=True)
        api.upload_folder(folder_path=str(merged_dir), repo_id=a.out, commit_message=f"loopl_sft.py {SCRIPT_VERSION}: merged weights")
        log(f"pushed merged → https://huggingface.co/{a.out}")
    export_artifacts(a, api, work, merged_dir, summary, scorecard,
                     {"conversations": len(train_s) + len(eval_s), "rows": len(ds), "steps": steps})


def reexport(a, token, work: Path):
    """--from-merged: conversions only, from an already pushed merged repo (cheap CPU job; no training)."""
    from huggingface_hub import HfApi, snapshot_download
    stage("download", repo=a.from_merged)
    merged_dir = Path(snapshot_download(a.from_merged, token=token, local_dir=str(work / "merged")))
    summary = json.loads((merged_dir / "train_summary.json").read_text()) if (merged_dir / "train_summary.json").exists() else {}
    scorecard = json.loads((merged_dir / "scorecard.json").read_text()) if (merged_dir / "scorecard.json").exists() else {}
    a.base = summary.get("base", a.base)
    a.dataset = summary.get("dataset", a.dataset)
    summary.setdefault("data", {"train": summary.get("scorecard", {}).get("train_conversations", 0),
                                "eval": summary.get("scorecard", {}).get("eval_conversations", 0), "revision": None})
    summary.setdefault("method", "lora"); summary.setdefault("rows", 0); summary.setdefault("tokens", 0)
    summary.setdefault("wall_s", 0); summary.setdefault("scorecard", scorecard)
    export_artifacts(a, HfApi(token=token), work, merged_dir, summary, scorecard,
                     {"conversations": summary["data"]["train"] + summary["data"]["eval"], "reexport_of": a.from_merged})


def export_artifacts(a, api, work: Path, merged_dir: Path, summary: dict, scorecard: dict, done_extra: dict):
    private = not a.public
    out_ids = {"merged": a.out, "mlx": None, "gguf": None}

    if not a.skip_mlx:
        stage("mlx", repo=a.out + "-4bit")
        try:
            mlx_dir = work / "mlx"
            convert_mlx(merged_dir, mlx_dir, a.q_bits, a.q_group)
            make_app_loadable(mlx_dir, a.base, os.environ.get("HF_TOKEN"), "mlx")
            (mlx_dir / "scorecard.json").write_text(json.dumps(scorecard, indent=1))
            (mlx_dir / "README.md").write_text(model_card(a, summary, "mlx", parent=a.out))
            if not a.no_push:
                api.create_repo(a.out + "-4bit", private=private, exist_ok=True)
                api.upload_folder(folder_path=str(mlx_dir), repo_id=a.out + "-4bit",
                                  commit_message=f"loopl_sft.py {SCRIPT_VERSION}: MLX {a.q_bits}-bit")
            out_ids["mlx"] = a.out + "-4bit"
            log(f"MLX → https://huggingface.co/{a.out}-4bit")
        except Exception as e:  # noqa: BLE001
            log(f"MLX conversion FAILED (merged model is still pushed): {e}")
            out_ids["mlx_error"] = str(e)[:500]

    if not a.skip_gguf:
        stage("gguf", repo=a.out + "-GGUF")
        try:
            name = a.out.split("/")[-1]
            gguf = convert_gguf(merged_dir, work / "gguf", name, a.llama_tag, a.gguf_quant)
            if not a.no_push:
                api.create_repo(a.out + "-GGUF", private=private, exist_ok=True)
                api.upload_file(path_or_fileobj=str(gguf), path_in_repo=gguf.name, repo_id=a.out + "-GGUF",
                                commit_message=f"loopl_sft.py {SCRIPT_VERSION}: {a.gguf_quant}")
                card = work / "gguf-README.md"
                card.write_text(model_card(a, summary, "gguf", parent=a.out))
                api.upload_file(path_or_fileobj=str(card), path_in_repo="README.md", repo_id=a.out + "-GGUF")
            out_ids["gguf"] = a.out + "-GGUF"
            out_ids["gguf_file"] = gguf.name
            log(f"GGUF → https://huggingface.co/{a.out}-GGUF/{gguf.name} ({gguf.stat().st_size/1e6:.0f} MB)")
        except Exception as e:  # noqa: BLE001
            log(f"GGUF conversion FAILED (merged model is still pushed): {e}")
            out_ids["gguf_error"] = str(e)[:500]

    done = {"out": out_ids, **done_extra,
            "eval_loss_base": scorecard.get("eval_loss_base"), "eval_loss_tuned": scorecard.get("eval_loss_tuned"),
            "tool_name_match": f"{scorecard.get('tool_name_match', 0)}/{scorecard.get('tool_turns', 0)}",
            "wall_s": round(time.time() - T0), "script": SCRIPT_VERSION}
    print("[loopl] done " + json.dumps(done), flush=True)


if __name__ == "__main__":
    main()
