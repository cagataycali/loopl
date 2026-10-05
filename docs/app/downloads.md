# Download flow

1. **Pick a model** in *Models*. Each row shows runtime, 4-bit size, nominal / usable context and
   minimum RAM; a star marks the default (`Qwen3-1.7B-4bit`, 968 MB).
2. **Headroom check.** Before anything is fetched the app compares the model's size + KV cache at the
   default context against `os_proc_available_memory()` and the free disk
   (`volumeAvailableCapacityForImportantUsage`). Not enough → a sheet explains exactly what is short.
3. **Download** straight from `huggingface.co` — only the files in that repo (`*.safetensors`,
   `config.json`, `tokenizer*.json`). Progress is size-weighted across files. A gated repo without a
   token shows *Needs a Hugging Face token with access* and links to Settings.
4. **Resume.** Leave the app and the download pauses (foreground session, ~30 s grace); come back and it
   resumes with `Range:` from the partial file. Partial files are kept until you delete the model.
5. **Loaded.** Tap a downloaded model to load it into memory; the row shows *Loaded* and the Chat tab
   starts using it. Loading another model unloads the first.
6. **Delete** removes the snapshot folder. Clear cache in Settings removes all of them.

## Where files live

`Application Support/loopl/models/<org>--<name>/` — never `Library/Caches` (purgeable), never
`Documents` (shows in Files and backups). The folder is marked excluded from backup so iCloud does not
try to upload gigabytes.

## Apple Foundation Models

Has no download step at all. If the OS is still fetching the system model you see *Apple is still
downloading the model*; that is the OS, not the app.
