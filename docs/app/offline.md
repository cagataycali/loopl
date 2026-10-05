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

The MLX runtime resolves the snapshot folder locally and never asks the Hub for the file list when the
files are present — so there is no spinner waiting for a timeout.

## Offline simulation

**Settings → Offline simulation** swaps the downloader for one that fails every request and marks
`Reachability.isOnline = false`, so you can test the branch without touching the Control Centre. The
Chat tab shows an *offline* pill while it is on.

## Memory, not network, is the risk

Offline or not, the only way a running generation stops unexpectedly is the OS evicting the app under
memory pressure. The headroom check before download and the usable-context default exist for that;
the Chat meter shows live available memory so you can see it coming.
