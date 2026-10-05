# loopl

**A native Swift agent SDK for on-device inference — the Strands event loop in Swift — and a free iOS app that runs any
public Hugging Face model offline.** No account, no token, no telemetry. Docs: **https://loopl.dev** · API: https://loopl.dev/api/

iOS 18+ · Swift 6 · SwiftUI. Measured on an iPhone 16 Pro: Qwen3-1.7B at **41 tok/s** (MLX 4-bit) and **33 tok/s**
(llama.cpp Q4_K_M), four tool calls in one turn.

## Install
```swift
// Package.swift
.package(url: "https://github.com/cagataycali/loopl", branch: "main")
// products: "Loopl" (core, Foundation only) · "LooplRuntimes" (MLX, Apple Intelligence, llama.cpp) · "LooplUI" (SwiftUI)
```
GGUF needs the official llama.cpp xcframework once: `scripts/fetch-llama-xcframework.sh --with-sim`.

## Use
```swift
import Loopl
import LooplRuntimes

let spec  = try await HubCatalog().resolve("mlx-community/Qwen3-1.7B-4bit")   // any public repo → ModelSpec
let model = MLXModel()                                                        // or GGUFModel(), AppleFoundationModel()
try await model.load(spec, from: weightsDirectory) { progress in }

let agent = Agent(model: model, tools: [CurrentTimeTool(), CalculatorTool()], systemPrompt: "Be brief.")
for try await event in agent.stream("What time is it in Istanbul, and what is 23 × 47?") {
    switch event {
    case .text(let chunk):        print(chunk, terminator: "")
    case .toolStarted(let use):   print("→", use.name, use.input)
    case .toolResult(let result): print("←", result.content)
    case .result(let r):          print("\n", r.stopReason, r.metrics.cycleCount, "cycles")
    default: break
    }
}
```
Strands, faithfully: stream → assemble → run tools (concurrently) → append → recurse until the model stops. No iteration
cap, no loop detector; `maxTokens` recovers the message and throws, as Strands does. Mapping: https://loopl.dev/sdk/strands-mapping/

## The app
`App/` is the free iOS app (`technology.tiny.loopl`): document-style chat, inline tool rows, Browse Hugging Face
(search MLX · GGUF, pick a quant, fit badge), models download once and run offline. Runtimes: MLX (Metal), Apple
Intelligence (iOS 26), llama.cpp (GGUF). Everything stays on the phone.

## Build
```sh
swift test                                                   # SDK, macOS
brew install xcodegen && xcodegen generate -s App/project.yml
xcodebuild -project App/LooplApp.xcodeproj -scheme loopl -destination 'generic/platform=iOS Simulator' build
DEVICE_ID=<udid> DEVELOPMENT_TEAM=<team> scripts/build-on-device.sh    # install + launch on an iPhone
```
First build resolves mlx-swift (large). Real llama.cpp tests on macOS: `LOOPL_GGUF_DIR=<dir with a .gguf> swift test --filter GGUFModelTests`.

## Honest notes
- Numbers above are from one phone and one prompt (`core2/device-proof`); the app shows *your* measured values, never ours.
- Tool-call grammars are verified on Qwen, Llama 3, Gemma, Phi, SmolLM, DeepSeek; other families run with the generic
  parser and are tagged "tool calls unverified".
- Apple Intelligence exposes no tokenizer, so its token counts are `chars/4` estimates (labelled).
Made by [@cagataycali](https://github.com/cagataycali).
