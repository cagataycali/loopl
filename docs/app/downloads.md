---
description: How the loopl app downloads models — anonymous, resumable, size-checked — and where the files live.
---

# Download flow

1. **First launch** downloads the default model (`mlx-community/Qwen3-0.6B-4bit`, ≈335 MB) by itself, with progress
   inline at the top of the chat. Later launches reload the last model you used.
2. **Pick another model** in *Models*. Each row shows size, parameters, the context budget for this device class and
   the runtime; tapping a row that is not on the phone starts its download and switches to it when done.
3. **Headroom check.** Before anything is fetched the app compares the model's `minRAMGB` against the device and its
   size against free disk space (`volumeAvailableCapacityForImportantUsage`). Not enough → a sheet explains what is short.
4. **Download** straight from `huggingface.co`, **anonymously** — only the files that repository needs
   (`*.safetensors` + `config.json` + tokenizer files for MLX, the one `.gguf` for llama.cpp). Progress is
   size-weighted across files. Gated repositories are not in the catalog, so there is never a token prompt.
5. **Resume.** Leave the app and the download pauses; come back and it resumes with `Range:` from the `.part` file.
   Partial files are kept until you delete the model.
6. **Loaded.** The loaded model is the one in the Chat title and marked ⚡ in the list. Loading another model unloads
   the first.
7. **Delete** by swiping a row, or *Delete all downloaded models* in Settings › Storage.

## Where files live

`Application Support/loopl/models/<model id>/` — never `Library/Caches` (purgeable), never `Documents` (shows in Files
and in backups). The folder is excluded from backup so iCloud does not try to upload gigabytes.

## Apple Intelligence

Has no download step. If the OS is still fetching the system model you see *Apple is still downloading the model*;
that is the OS, not the app.
