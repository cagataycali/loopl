# Model protocol

Everything the agent needs from an LLM. A `Model` is an **actor** that owns loaded weights; it does not download —
that is the job of `HFDownloader` (SDK) and the app's model store.

```swift
public protocol Model: Actor {
    nonisolated var kind: RuntimeKind { get }       // .mlx · .appleFM · .gguf
    var loadedModelId: String? { get }              // ModelSpec.id while loaded

    /// Load weights from `directory` (nil for runtimes that have none, e.g. Apple FM).
    /// `progress` is 0…1 for weight loading.
    func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws
    func unload() async

    /// One model turn. Emit .text deltas, .toolCall if you parse calls natively, .metrics snapshots.
    nonisolated func stream(messages: [Message], tools: [any Tool], params: GenerationParams)
        -> AsyncThrowingStream<ModelEvent, Error>

    /// Can this runtime run at all on this build/device (Metal, OS version, Apple Intelligence)?
    nonisolated static func availability() -> RuntimeAvailability
}

public struct RuntimeAvailability: Sendable, Hashable {
    public var available: Bool
    public var reason: String          // "needs iOS 26 or later", "Apple Intelligence is off — Settings › …", …
    public static let ok: RuntimeAvailability
}

public struct ModelError: LocalizedError, Sendable { public let message: String }
```

## ModelSpec & Catalog

The catalog is a bundled `models.json` (the same file [Models](../models.md) is generated from):

```swift
public struct ModelSpec: Codable, Sendable, Identifiable, Hashable {
    public var id: String              // "qwen3-1.7b-4bit"
    public var name: String
    public var repo: String            // Hugging Face repo id
    public var runtime: RuntimeKind
    public var family: ToolFamily      // tool-call dialect
    public var paramsB: Double
    public var sizeBytes: Int64        // 4-bit weights on disk
    public var ctxNominal: Int         // max_position_embeddings
    public var ctxUsable8GB: Int       // what fits on an 8 GB iPhone
    public var minRAMGB: Double
    public var gated: Bool
    public var notes: String?
    public var revision: String?
    public var chatTemplateKwargs: [String: JSONValue]?   // e.g. ["enable_thinking": false]
    public var sizeLabel: String; public var isDownloadable: Bool   // false for Apple FM
}

public struct Catalog: Codable, Sendable {
    public var version: Int, updated: String, models: [ModelSpec]
    public static func loadBundled() -> Catalog
}
```

## Downloading

```swift
let hub = HFDownloader(token: nil)                       // or the Keychain token for gated repos
let files = try await hub.listFiles(repo: spec.repo)     // .safetensors, config.json, tokenizer*.json …
                 .filter(HFDownloader.wanted)
let dir = modelsRoot.appendingPathComponent(spec.id)
var done: Int64 = 0
for f in files {
    try await hub.download(repo: spec.repo, file: f, to: dir.appendingPathComponent(f.path)) { delta in
        done += delta                                     // bytes written in THIS call → sum for progress
    }
}
```

- Writes to `<dest>.part` and resumes with `Range:` from the partial size; a complete file is skipped.
- Throws `DLError.offline` immediately when `NetworkPolicy.isOffline` — no spinner waiting for a timeout.
- Sends `Authorization: Bearer` **only** when a token is set, only to `huggingface.co`.
- Put `modelsRoot` in Application Support and mark it `isExcludedFromBackup` (the app does).

## Loading & running

```swift
let model = MLXModel()
try await model.load(spec, from: dir) { p in print("load", p) }
let agent = Agent(model: model, tools: [CurrentTimeTool()])
```

`MLXModel.load` sets `MLX.GPU.set(cacheLimit: 32 MB)`, builds the container from the directory (no network), and
throws `ModelError("<name> is not downloaded")` if `directory` is nil. `unload()` clears the Metal cache.

## FakeModel

A scripted actor for tests, previews and the app's **Demo (scripted)** switch — clearly labelled, never a benchmark.

```swift
let fake = FakeModel(scripts: [
    #"<tool_call>{"name":"current_time","arguments":{"timezone":"Europe/Istanbul"}}</tool_call>"#,
    "It is 09:12 in Istanbul."
])
let agent = Agent(model: fake, tools: [CurrentTimeTool()])
let r = try await agent("time in istanbul?")
#expect(r.iterations == 2 && r.toolResults.count == 1)
```

Each `stream()` plays the next script entry word by word (`delayPerChunkNs` to simulate speed; `fallback` when the
script runs out; `seenPrompts` records what the agent sent). Twenty scripted tool calls in a row is how the unlimited
loop and the detector are tested without a GPU — see `Tests/LooplTests/AgentTests.swift`.

## Implementing your own

Emit `.text` deltas, emit `.toolCall` only if you parse calls yourself (otherwise the agent parses the text by
`AgentConfig.family`), send `.metrics` with `finished = true` at the end, honour `Task.isCancelled` between tokens.
`Sources/LooplRuntimes/MLXModel.swift` is the reference; `Sources/Loopl/FakeModel.swift` is the minimum viable one.
