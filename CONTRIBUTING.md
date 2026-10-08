# Contributing

loopl is a Swift 6 package (the SDK) and an iOS app built on it. Everything runs on the device.

## Build

```sh
swift test                                                     # the SDK, on macOS
brew install xcodegen && xcodegen generate -s App/project.yml  # the app → App/LooplApp.xcodeproj
scripts/fetch-llama-xcframework.sh --with-sim                  # once, for the GGUF runtime
```

Open `App/LooplApp.xcodeproj`, pick a simulator, run. To install on your own iPhone set
`DEVELOPMENT_TEAM` in `App/project.yml` to your team (or pass it to `scripts/build-on-device.sh`).

## Before you open a pull request

- `swift test` passes. The app's UI tests (`App/UITests`) run in `.github/workflows/ui.yml` on `main`.
- A user-visible change gets one fragment in `docs/changelog.d/<pr>-<slug>.md` (see the README there).
- Copy in the app is plain words: say what happens, not a status code. `Tests/LooplTests/PlainWordsTests.swift`
  pins the sentences that were retired and why.
- `App/Resources/train/loopl_sft.py` is a byte-for-byte mirror of the training script; edit it upstream and run
  `scripts/sync-train-script.sh`, never by hand.

## Where things are

| | |
|---|---|
| `Sources/Loopl` | agent loop, `Model`/`Tool`, parsers, prompts, catalog, Hugging Face client — Foundation only |
| `Sources/LooplRuntimes` | MLX, llama.cpp (GGUF), Apple Foundation Models |
| `Sources/LooplAppleTools` | the phone's abilities as tools |
| `Sources/LooplUI` | SwiftUI transcript, tool rows, cards |
| `App/` | the iOS app, its UI tests and App Store assets |
| `docs/` | loopl.dev (mkdocs) |

Questions and bugs: [open an issue](https://github.com/cagataycali/loopl/issues).
