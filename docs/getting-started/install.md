# Install (SwiftPM)

## Add the package

=== "Package.swift"

    ```swift
    // swift-tools-version: 6.0
    dependencies: [
        .package(url: "https://github.com/cagataycali/loopl.git", from: "0.1.0"),
    ],
    targets: [
        .target(name: "MyApp", dependencies: [
            .product(name: "Loopl",         package: "loopl"),  // core: Agent, Tool, Model, Message, events
            .product(name: "LooplRuntimes", package: "loopl"),  // MLXModel, AppleFoundationModel, GGUFModel
            .product(name: "LooplUI",       package: "loopl"),  // SwiftUI components (optional)
        ]),
    ]
    ```

=== "Xcode"

    **File → Add Package Dependencies…** → paste `https://github.com/cagataycali/loopl.git` → add the
    `Loopl`, `LooplRuntimes` and (optionally) `LooplUI` products to your app target.

=== "xcodegen"

    ```yaml
    packages:
      Loopl:
        url: https://github.com/cagataycali/loopl.git
        from: 0.1.0
    targets:
      MyApp:
        dependencies:
          - package: Loopl
            product: Loopl
          - package: Loopl
            product: LooplRuntimes
    ```

`Loopl` is pure Swift (Foundation only) and builds everywhere — macOS, Linux, the simulator — which is
what makes the agent loop unit-testable with `FakeModel`. `LooplRuntimes` pulls in
[`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) `3.32.3` (products `MLXLLM` + `MLXLMCommon` only) and
[`swift-transformers`](https://github.com/huggingface/swift-transformers) `1.3.4` (`Tokenizers` + `Hub`), pinned `exact:` in
`Package.swift`. Platforms: iOS 18, macOS 14.

## Entitlement: Increased Memory Limit

Add `com.apple.developer.kernel.increased-memory-limit` to your app's entitlements. Without it iOS
jetsams an iPhone 16 Pro while loading a 1.7B 4-bit model
([mlx-swift-lm #492](https://github.com/ml-explore/mlx-swift-lm/issues/492)).

```xml title="MyApp.entitlements"
<key>com.apple.developer.kernel.increased-memory-limit</key>
<true/>
```

No other capability is required. `AppleFoundationModel` needs nothing extra; the system asks the user
nothing because the model is already on the device.

## Versions that matter

| Dependency | Pin | Why |
|---|---|---|
| `mlx-swift-lm` | `3.32.3` exact; link only `MLXLLM` + `MLXLMCommon`, **never `MLXHuggingFace`** | its macros pull `MLXFoundationModels`, which needs iOS 27 types under the default trait |
| `mlx-swift` | ≥ 0.30.6 (transitive) | #462: gibberish output on iPhone 16 Pro before that |
| `swift-transformers` | `1.3.4` exact | `applyChatTemplate(messages:tools:additionalContext:)` for tool specs + `enable_thinking` |

`Package.swift` pins these; the table is here so you know what to expect if you override them.
