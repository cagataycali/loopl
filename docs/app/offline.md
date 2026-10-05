---
description: loopl works in airplane mode — what happens to models, tools and downloads when the phone is offline, and the in-app offline switch.
---

# Offline mode

The point of loopl is that the model is *on the phone*. Turn on airplane mode and a model that is already
downloaded keeps answering.

## What happens offline

| | Online | Offline |
|---|---|---|
| Model already on disk | loads, no network call | loads, **no network call** |
| Model not on disk | downloads | *Download needs a connection* — nothing is attempted |
| Apple Foundation Models | works | works |
| `current_time`, `calculator`, `device_info`, `remember/recall` | work | work |
| `http_get` | works | returns `error: offline` to the model, which explains it to you |

`MLXModel.load(spec, from: dir)` reads the directory and never touches the Hub; a complete file is skipped by the
downloader without a request — so there is no spinner waiting for a timeout.

## Offline simulation

**Settings → Offline mode** sets `NetworkPolicy.isOffline`: `HFDownloader` throws `DLError.offline` before opening a
connection and `http_get` answers `offline mode is on — network refused`, so you can test the branch without touching
the Control Centre. The Chat toolbar shows an airplane badge while it is on.

## Memory, not network, is the risk

Offline or not, the only way a running generation stops unexpectedly is the OS evicting the app under
memory pressure. The headroom check before download and the per-model context budget (`ctxUsable8GB`) exist for that;
*Show performance details* adds a quiet footer line with context used / max so you can see it coming.
