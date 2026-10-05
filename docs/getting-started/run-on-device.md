# Run on a device

MLX needs Metal; the iOS simulator has no Metal JIT. Build and launch the simulator for UI work, run
inference on a real phone.

## Xcode

1. Select your iPhone as the run destination (USB or paired Wi-Fi).
2. Set your team in **Signing & Capabilities**; keep the **Increased Memory Limit** capability on.
3. **⌘R**. First launch downloads the model you picked (Qwen3-1.7B-4bit is 968 MB).

## Command line

```bash
UDID=$(xcrun devicectl list devices --json-output /dev/stdout | python3 -c \
  'import json,sys;d=json.load(sys.stdin)["result"]["devices"];print(d[0]["identifier"])')

xcodebuild -scheme MyApp -configuration Debug -destination "id=$UDID" \
  -derivedDataPath /tmp/dd DEVELOPMENT_TEAM=YOURTEAM build

xcrun devicectl device install app --device "$UDID" /tmp/dd/Build/Products/Debug-iphoneos/MyApp.app
xcrun devicectl device process launch --device "$UDID" com.example.MyApp
```

## Memory

Before the first `load()` the runtime calls `GPU.set(cacheLimit: 32 * 1024 * 1024)` and reads
`os_proc_available_memory()`; `MemoryBudget.current` is what the app shows as the headroom meter.

| Phone | RAM | safe per-app | fits comfortably |
|---|---|---|---|
| iPhone 15 Pro / 16 / 16 Pro | 8 GB | ~5–6 GB | ≤ 4B params at 4-bit, 8k context |
| iPhone 17 Pro | 12 GB | ~8–9 GB | 7B/8B at 4-bit, 8k–16k context |
| iPad Pro (M4) | 8–16 GB | ~6–12 GB | same as above by RAM |

`MLXModel.load()` throws `ModelError.insufficientMemory(needed:available:)` instead of letting the kernel
jetsam you. The app surfaces that as a warning sheet before download.

## Airplane-mode proof

A model already on disk answers with Wi-Fi and cellular off. `HubApi` is never touched after the files
are present; only tools that explicitly need the network (`http_get`, `weather`) check reachability
themselves. See [Offline mode](../app/offline.md).
