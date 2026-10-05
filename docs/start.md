---
title: Get started
description: Install loopl with SwiftPM, download a public model, run an agent with tools on an iPhone — one page.
---

# Get started

Three steps: add the package, fetch a model, run the loop. iOS 18+, Swift 6, Xcode 26.

## 1 · Install

=== "Package.swift"

    ```swift
    dependencies: [
        .package(url: "https://github.com/cagataycali/loopl.git", from: "0.1.0"),
    ],
    targets: [
        .target(name: "MyApp", dependencies: [
            .product(name: "Loopl", package: "loopl"),          // Agent, Tool, Model, Message — Foundation only
            .product(name: "LooplRuntimes", package: "loopl"),  // MLXModel, AppleFoundationModel, GGUFModel
            .product(name: "LooplUI", package: "loopl"),        // SwiftUI transcript, tool rows, token meter
        ]),
    ]
    ```

=== "Xcode"

    **File → Add Package Dependencies…** → `https://github.com/cagataycali/loopl.git` → add `Loopl`, `LooplRuntimes`, `LooplUI`.

Add the **Increased Memory Limit** entitlement (`com.apple.developer.kernel.increased-memory-limit`) — without it iOS caps the app well below what a 1.7B model needs.

## 2 · Fetch a model

Public repos only, anonymous, resumable. The bundled catalog lists [21 models](models.md); any Hugging Face repo id works the same way.

```swift
// snippet: compile(runtimes)
import Loopl
import LooplRuntimes
import Foundation

/// Downloads a catalog model into Application Support and returns its folder.
func fetch(_ id: String) async throws -> (ModelSpec, URL) {
    let spec = Catalog.loadBundled().models.first { $0.id == id }!            // e.g. "qwen3-0.6b-4bit"
    let root = URL.applicationSupportDirectory.appending(path: "loopl/models/\(spec.id)")
    let hf = HFDownloader()                                                     // no token
    for file in try await hf.files(for: spec) {
        try await hf.download(repo: spec.repo, file: file, to: root.appending(path: file.path)) { bytes in
            print("\(file.path): \(bytes) / \(file.size)")
        }
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
    let model = MLXModel()                                       // Metal — a real device, not the simulator
    try await model.load(spec, from: dir) { p in print("loading \(Int(p * 100)) %") }

    let agent = Agent(model: model,
                      tools: [CurrentTimeTool(), CalculatorTool()],
                      systemPrompt: "You are a concise assistant running on the user's phone.")

    for try await event in agent.stream("What time is it in Istanbul, and what is 23 × 47?") {
        switch event {
        case .text(let t):            print(t, terminator: "")
        case .toolStarted(let use):   print("\n→ \(use.name) \(use.input)")
        case .toolResult(let r):      print("← \(r.content)")
        case .result(let r):          print("\n\(r.metrics.cycleCount) cycles")   // 2: one tool round, then the answer
        default: break
        }
    }
}
```

The loop runs until the model stops calling tools. There is no iteration cap — the context window and your Stop button are the bounds.

## On the phone

- **MLX needs Metal.** The simulator has no Metal JIT: use `GGUFModel` (CPU) there, run MLX on a device.
- **Memory.** 8 GB phones (iPhone 15 Pro–16 Pro) fit ≤ 4B parameters at 4-bit with 8k context; 12 GB (17 Pro) fits 7–8B. `ModelSpec.minRAMGB` is the check the app runs before a download.
- **Offline.** `load(spec, from:)` reads the folder and never touches the network — airplane mode works once the files are on disk.
- **GGUF.** Run `scripts/fetch-llama-xcframework.sh --with-sim` once to vendor llama.cpp; without it `GGUFModel.availability()` tells you why it is unavailable.

Next: [Agent & event loop](sdk/agent.md) · [Tools](sdk/tools.md) · [Models & runtimes](sdk/models.md) · [the app](app/index.md)
