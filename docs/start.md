---
title: "Get started"
description: "Add the Swift package, fetch a public model, run an agent with tools on the iPhone."
hide:
  - navigation
---

# Get started

Add the package, fetch a model, run the loop. iOS 18+, Swift 6, Xcode 26.

## 1 · Add the package

```swift
dependencies: [
    .package(url: "https://github.com/cagataycali/loopl.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Loopl", package: "loopl"),            // Agent, Tool, Model — Foundation only
        .product(name: "LooplRuntimes", package: "loopl"),    // MLX, llama.cpp, Apple Foundation Models
        .product(name: "LooplAppleTools", package: "loopl"),  // generate_image, flashlight, open_app, …
        .product(name: "LooplUI", package: "loopl"),          // SwiftUI transcript, tool rows, approval card
    ]),
]
```

Add the **Increased Memory Limit** entitlement (`com.apple.developer.kernel.increased-memory-limit`) — without it iOS caps the app below what a 1.7B model needs.

## 2 · Fetch a model

Public repos, anonymous, resumable. Any Hugging Face repo id works; see the [bundled catalog](models.md).

```swift
// snippet: compile(runtimes)
import Loopl
import LooplRuntimes
import Foundation

func fetch(_ id: String) async throws -> (ModelSpec, URL) {
    let spec = Catalog.loadBundled().models.first { $0.id == id }!            // e.g. "qwen3-0.6b-4bit"
    let root = URL.applicationSupportDirectory.appending(path: "loopl/models/\(spec.id)")
    let hf = HFDownloader()
    for file in try await hf.files(for: spec) {
        try await hf.download(repo: spec.repo, file: file, to: root.appending(path: file.path)) { _ in }
    }
    return (spec, root)
}
```

## 3 · Run the loop

```swift
// snippet: compile(runtimes)
import Loopl
import LooplRuntimes
import Foundation

func chat(_ spec: ModelSpec, at dir: URL) async throws {
    let model = MLXModel()                                       // Metal — a real device
    try await model.load(spec, from: dir) { _ in }

    let agent = Agent(model: model,
                      tools: [CurrentTimeTool(), CalculatorTool()],
                      systemPrompt: "You are a concise assistant on the user's phone.")

    for try await event in agent.stream("What time is it in Istanbul, and what is 23 × 47?") {
        switch event {
        case .text(let t):            print(t, terminator: "")
        case .toolStarted(let use):   print("\n→ \(use.name)")
        case .toolResult(let r):      print("← \(r.content)")
        default: break
        }
    }
}
```

The loop runs until the model stops calling tools — no iteration cap.

## Good to know

- **MLX needs Metal.** On the simulator use `GGUFModel` (CPU); run MLX on a device.
- **Memory.** 8 GB phones fit ≤ 4B parameters at 4-bit with 8k context. `ModelSpec.minRAMGB` is the check.
- **Offline.** `load(spec, from:)` reads the folder and never touches the network.
- **GGUF.** Run `scripts/fetch-llama-xcframework.sh --with-sim` once; until then `GGUFModel.availability()` says why it can't run.

Next: [Agent](sdk/agent.md) · [Tools](sdk/tools.md) · [Runtimes](sdk/models.md)
