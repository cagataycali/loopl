# loopl

**The Swift SDK for agents that run on the device.** A local model, the agent loop and the iPhone's own abilities as
tools — offline, no account, no cloud. Plus a free iOS app that shows it off.

[loopl.dev](https://loopl.dev) · [Get started](https://loopl.dev/start/) · [API](https://loopl.dev/api/)

```swift
.package(url: "https://github.com/cagataycali/loopl", from: "0.1.0")
```

```swift
import Loopl
import LooplRuntimes
import LooplAppleTools

let model = MLXModel()                                   // or GGUFModel(), AppleFoundationModel()
try await model.load(spec, from: weights) { _ in }

let agent = Agent(model: model, tools: AppleTools.available)   // what this iPhone can do
for try await event in agent.stream("Torch on, and how do I say 'where is the exit?' in Turkish?") {
    if case .text(let chunk) = event { print(chunk, terminator: "") }
}
```

The loop is model → tools → model, until the model answers. No iteration cap.

| Product | |
|---|---|
| `Loopl` | `Agent`, `Tool`, `Model`, hooks, structured output, checkpoints, tracing — Foundation only |
| `LooplRuntimes` | MLX (Metal, vision), llama.cpp (GGUF), Apple Foundation Models |
| `LooplAppleTools` | `generate_image`, `generate_voice`, `transcribe`, `translate`, `describe_image`, `flashlight`, `vibrate`, `open_app` |
| `LooplUI` | SwiftUI transcript, tool rows, approval card |

Qwen3-1.7B on an iPhone 16 Pro: **41 tok/s** (MLX 4-bit), **33 tok/s** (llama.cpp Q4_K_M).

```sh
swift test                                                     # SDK, macOS
brew install xcodegen && xcodegen generate -s App/project.yml  # the app → App/LooplApp.xcodeproj
scripts/fetch-llama-xcframework.sh --with-sim                  # once, for GGUF
```

Made by [@cagataycali](https://github.com/cagataycali).
