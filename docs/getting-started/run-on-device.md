# Run on a device

MLX needs Metal; the iOS simulator has no Metal JIT. Build and launch the simulator for UI work, run
inference on a real phone.

## Xcode

1. Select your iPhone as the run destination (USB or paired Wi-Fi).
2. Set your team in **Signing & Capabilities**; keep the **Increased Memory Limit** capability on.
3. **⌘R**. In the app: Models → Qwen3-1.7B (4-bit) → Download (968 MB) → Load → Chat.

The repo's `scripts/build-on-device.sh` does the same from the terminal (`DEVELOPMENT_TEAM=<team> scripts/build-on-device.sh`):
xcodegen → `xcodebuild -destination id=<udid>` → `devicectl device install app` → `process launch`.

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

Before the first `load()` the runtime calls `MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)`; the app reads
`os_proc_available_memory()` (its `MemoryBudget`) for the headroom meter and the pre-download warning.

| Phone | RAM | safe per-app | fits comfortably |
|---|---|---|---|
| iPhone 15 Pro / 16 / 16 Pro | 8 GB | ~5–6 GB | ≤ 4B params at 4-bit, 8k context |
| iPhone 17 Pro | 12 GB | ~8–9 GB | 7B/8B at 4-bit, 8k–16k context |
| iPad Pro (M4) | 8–16 GB | ~6–12 GB | same as above by RAM |

The app refuses a download that cannot fit (`ModelSpec.minRAMGB` vs the device) and warns before loading; the SDK
itself keeps `GenerationParams.contextLength` as the KV-cache cap so a long chat degrades instead of jetsamming.

## Airplane-mode proof

A model already on disk answers with Wi-Fi and cellular off: `MLXModel.load(spec, from: dir)` reads the directory and
makes no network call. `HFDownloader` and `HttpGetTool` both check `NetworkPolicy.isOffline` and fail fast with a clear
message instead of waiting for a timeout. See [Offline mode](../app/offline.md).
