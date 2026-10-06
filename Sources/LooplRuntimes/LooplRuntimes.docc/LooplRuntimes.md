# ``LooplRuntimes``

Three on-device engines behind one `Model` protocol.

## Overview

``MLXModel`` runs Hugging Face MLX checkpoints on Metal, vision ones included. ``GGUFModel`` runs any `.gguf` through llama.cpp, on the simulator too. ``AppleFoundationModel`` uses the model already on the phone (iOS 26, Apple Intelligence on). None of them touch the network — weights come from a local directory.

Ask `availability()` first; it says why an engine can't run here. Watch what the model actually read with ``MLXModel/setTrace(_:)`` and ``GenerationTrace``.

## Topics

### Engines

- ``MLXModel``
- ``GGUFModel``
- ``AppleFoundationModel``

### Seeing inside

- ``GenerationTrace``
