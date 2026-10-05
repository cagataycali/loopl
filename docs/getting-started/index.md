---
description: Start with loopl — add the Swift package, run your first on-device agent, put it on an iPhone.
---

# Getting started

loopl is two things that share one agent loop:

1. **The SDK** — Swift packages `Loopl` (core), `LooplRuntimes` (MLX · Apple Foundation Models · GGUF) and
   `LooplUI` (SwiftUI components). Add it with SwiftPM and ship agents inside your own app.
2. **The app** — a free iOS app that downloads Hugging Face models and runs them offline with the same loop.
   No account, no analytics. [About the app →](../app/index.md)

<div class="grid cards" markdown>

- :material-package-down: **[Install](install.md)** — add the package, pick the products you need, set the
  one entitlement that keeps the GPU from being jetsammed.
- :material-robot-outline: **[Your first agent](first-agent.md)** — a model, two tools, an async stream of events.
- :material-cellphone-arrow-down: **[Run on a device](run-on-device.md)** — MLX needs Metal, so the simulator
  is for UI only; here is the device recipe.

</div>

## Requirements

| | Minimum | Recommended |
|---|---|---|
| iOS | 18.0 | 26.0 (Apple Foundation Models, zero-download) |
| Device | any arm64 iPhone/iPad with ≥ 6 GB RAM | iPhone 15 Pro / 16 / 16 Pro (8 GB) |
| Xcode | 16.x | 26.x |
| Swift | 6.0 language mode | 6.0 |
| Network | only for the first download of a model | — |

!!! note "Simulator"
    MLX compiles Metal kernels at runtime, which the iOS simulator cannot do — run `MLXModel` on a device.
    `GGUFModel` does run in the simulator (CPU only, `availability().reason` says so) and `Loopl`'s tests drive the
    whole loop with a scripted `FakeModel` (in `Tests/`) on a Mac, so UI work and previews never need weights.
