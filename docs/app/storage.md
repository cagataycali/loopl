---
title: "Storage"
description: "Keep models on the iPhone or on a USB-C drive — grant one folder, move models with a verified copy, carry on when the drive is away."
hide:
  - navigation
---

# Storage

A 4B model is two to three gigabytes; a phone fills up. **Settings › Storage** lets loopl keep models on a USB-C drive plugged into the iPhone — or on any folder a Files provider offers — next to the ones on the phone.

## Granting a drive

Plug the drive in, tap **Use an external drive…**, pick a folder. loopl keeps a security-scoped bookmark to that folder and nothing else: it reads and writes inside it, never elsewhere on the drive. The grant is re-opened on every launch; if it stops resolving (the drive was reformatted, the folder removed) the drive shows as *not connected* and **Forget** clears it. The files on the drive are never deleted by forgetting.

Each volume shows free space as iOS reports it for an important write (`volumeAvailableCapacityForImportantUsage`). Every download and move is checked against the **target** volume first, keeping 200 MB free — a stick with zero bytes free corrupts its own directory.

## Where downloads go

**Download new models to** picks the default. When that drive is away or full, the download falls back to the iPhone; when the iPhone cannot hold the model, to any connected drive that can. Downloads write straight to the target volume (resumable `.part` files included), so a model larger than the phone's free space is fine as long as the drive has room.

## Moving a model

**Move to SanDisk** / **Move to this iPhone** — in Settings › Storage or from a model row's menu. A move copies every file, verifies each copy (byte count for every file; SHA‑256 as well for everything up to 64 MB — config, tokenizer, manifests), and only then removes the original. A move that fails or is cancelled removes the half-written copy and leaves the model exactly where it was. Progress shows in the row.

## When the drive is unplugged

Models on it stay in the catalog, dimmed: *Needs SanDisk — plug it in to use*. They cannot be deleted from the phone (there is nothing on the phone to delete), and tapping one does nothing. If the model in use lived there and the drive is pulled, the next load says so by name — *SanDisk was disconnected while loading…* — and the app keeps running; at launch, loopl starts on the default model and leaves a note in the conversation. The default model and Apple's model always live on the phone, so the app works without the drive.

## When the drive is here but can't be read

iOS occasionally refuses a saved grant — most often for a bookmark to the **root** of a removable drive, or when the drive mounts a few seconds after loopl launched. loopl retries for about ten seconds and again every time it returns to the foreground. If the grant still fails, the drive row says **connected, but loopl can't read folder …** with **Re-grant folder…**: pick the same folder again and every model on it is back, nothing is downloaded twice. Prefer granting a sub-folder (for example `loopl`) rather than the drive root. **Diagnostics** at the bottom of the screen shares a small log of every grant, mount, listing and write outcome.

## Speed — the honest part

Weights load more slowly from a drive than from the iPhone's own flash.

| Phone | USB port | Qwen3.5‑0.8B (650 MB) | Qwen3‑4B (2.3 GB) |
|---|---|---|---|
| iPhone 15 Pro / 16 Pro | USB 3 (10 Gb/s; real drives 400–700 MB/s) | ~1–2 s | ~4–6 s |
| iPhone 15 / 16 (non‑Pro) | USB 2 (~40 MB/s) | ~16 s | ~60 s |

These are load-time estimates from drive throughput, not device measurements — the simulator cannot speak USB. MLX reads the weights into memory at load, so generation speed afterwards is the same from either place. GGUF (llama.cpp) memory-maps the file: on a drive, the first tokens after a load page in from USB and are slower; keep GGUF models on the phone when they fit.

!!! note "Device proof pending"
    The round trip — grant a folder, move Qwen3.5‑0.8B to the drive, run a chat — is proven on the simulator with a folder standing in for the drive. The owner's SanDisk on the iPhone 16 Pro is the remaining step and will update the table above with measured numbers.
