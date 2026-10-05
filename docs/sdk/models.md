---
description: The Model protocol every loopl runtime implements — load, stream Bedrock-shaped events, unload — plus ModelSpec, the catalog, anonymous downloads and GenerationParams.
---

# Model protocol

Everything the agent needs from an LLM. A `Model` is an **actor** that owns loaded weights and turns a conversation into a
stream of `StreamEvent`s. It does not download — that is `HFDownloader`'s job — and it does not know about tools beyond
their specs: parsing calls out of raw text is done for it by `ToolCallStreamGate` when the runtime has no native tool API.

```swift
public protocol Model: Actor {
    nonisolated var kind: RuntimeKind { get }                  // .mlx · .appleFM · .gguf
    var loadedModelId: String? { get }                         // ModelSpec.id while loaded
    var params: GenerationParams { get }                       // Strands get_config
    func updateConfig(_ params: GenerationParams)              // Strands update_config

    /// Load weights from `directory` (nil for runtimes that have none, e.g. Apple Foundation Models).
    func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws
    func unload() async

    /// One model turn, as the Bedrock-shaped stream Strands uses: messageStart → contentBlock* → messageStop(stopReason) → metadata.
    nonisolated func stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?)
        -> AsyncThrowingStream<StreamEvent, Error>

    /// Can this runtime run at all on this build/device (Metal, OS version, Apple Intelligence)?
    nonisolated static func availability() -> RuntimeAvailability
}
```

This is Strands' `Model` interface (`stream(messages, tool_specs, system_prompt)`, `get_config`/`update_config`) with the
on-device additions `load`/`unload`/`availability`. The three shipped runtimes are on [Runtimes](../runtimes/index.md).

## Errors the loop understands

| Error                         | Thrown by the model when…                              | What the loop does                                           |
|-------------------------------|--------------------------------------------------------|--------------------------------------------------------------|
| `ContextWindowOverflowError`  | the prompt does not fit `params.contextLength`         | `conversationManager.reduceContext` → retry the cycle        |
| `ModelThrottledError`         | a transient failure (GPU busy, warming up)             | retry with backoff, `AgentEvent.throttle(delay:)`            |
| `MaxTokensReachedError`       | *(not thrown by models — they emit `messageStop(.maxTokens)`)* | append the recovered partial message, throw it to the caller (`agent()` continues) |
| `ModelError`                  | anything else (not loaded, bad weights)                | `EventLoopError` → `.forceStop`, then `.result`              |

## GenerationParams

```swift
public struct GenerationParams: Sendable, Hashable, Codable {
    public var temperature: Float = 0.6
    public var topP: Float = 0.95
    public var minP: Float = 0
    public var maxTokens: Int? = nil          // nil = until the model stops (or the context is full)
    public var contextLength: Int = 8192      // the KV budget; the catalog's ctxUsable8GB per model
    public var seed: UInt64? = nil
}
```

Defaults are "max out": no output cap, context from the catalog. `temperature` is overridden per model when the catalog
row carries one (`ModelSpec.temperature`).

## ModelSpec & Catalog

The catalog is a bundled `models.json` — the same file the [Models](../models.md) table is generated from:

```swift
public struct ModelSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String              // "qwen3-1.7b-4bit"
    public var name: String
    public var repo: String            // Hugging Face repo id ("" for Apple FM)
    public var runtime: RuntimeKind
    public var family: ToolFamily      // tool-call dialect: hermes · llama3 · generic
    public var paramsB: Double
    public var sizeBytes: Int64        // weights on disk
    public var ctxNominal: Int         // max_position_embeddings
    public var ctxUsable8GB: Int       // what fits beside the weights on an 8 GB iPhone
    public var minRAMGB: Double
    public var gated: Bool             // always false in the shipped catalog — loopl lists public repos only
    public var notes: String?
    public var revision: String?
    public var file: String?           // single-file runtimes (GGUF): the one file to download
    public var temperature: Float?
    public var chatTemplateKwargs: [String: JSONValue]?   // e.g. enable_thinking: false for Qwen3
}

public struct Catalog: Sendable, Codable {
    public var version: Int
    public var updated: String
    public var models: [ModelSpec]
    public var defaultModelId: String?                     // "qwen3-0.6b-4bit" — downloaded on first launch
    public static func loadBundled(_ bundle: Bundle = .main) -> Catalog
}
```

## Downloads — anonymous, resumable, offline-aware

```swift
public struct HFDownloader: Sendable {
    public init()                                                 // no token: public repositories only
    public func files(for spec: ModelSpec) async throws -> [RemoteFile]            // the files a runtime needs
    public func listFiles(repo: String, revision: String = "main", filter: Bool = true) async throws -> [RemoteFile]
    public func download(repo: String, revision: String = "main", file: RemoteFile, to dest: URL,
                         onBytes: @Sendable @escaping (Int64) -> Void) async throws       // cumulative bytes
}
```

`download` writes to a `.part` file and resumes with `Range` requests, skips files already complete on disk, and throws `DLError.offline` before opening a socket when
`NetworkPolicy.isOffline` is set. A gated repository is refused with a readable `DLError.gated` — there is no token to
paste anywhere. `files(for:)` knows that an MLX repo needs `*.safetensors` + `config.json` + tokenizer files while a GGUF
spec is one file.

## Implementing a Model

A runtime has three jobs: load weights, produce tokens, report when it stops. Everything else is shared code:

```swift
// snippet: compile
import Loopl
import Foundation

actor EchoModel: Model {
    nonisolated let kind: RuntimeKind = .gguf
    private(set) var loadedModelId: String?
    private(set) var params = GenerationParams()

    func updateConfig(_ p: GenerationParams) { params = p }
    func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        loadedModelId = spec.id; progress(1)
    }
    func unload() async { loadedModelId = nil }

    nonisolated func stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?)
        -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { c in
            c.yield(.messageStart(role: .assistant))
            c.yield(.contentBlockStart(.text))
            c.yield(.contentBlockDelta(.text("You said: \(messages.last?.text ?? "")")))
            c.yield(.contentBlockStop)
            c.yield(.messageStop(.endTurn))
            c.finish()
        }
    }

    nonisolated static func availability() -> RuntimeAvailability { .ok }
}
```

For a token-producing runtime, pipe each decoded token through a `ToolCallStreamGate(family:)`: it buffers text that
*might* be the start of a tool call, emits plain text immediately, and converts a complete call into the
`contentBlockStart(.toolUse)` / `contentBlockDelta(.toolUse(input:))` pair. `MLXModel` and `GGUFModel` do exactly this.

!!! info "Testing without weights"
    The package's tests use a `FakeModel` actor whose `Turn`s script the stream — `.text`, `.toolUse`, `.markup`
    (raw `<tool_call>` text through the gate), `.maxTokens`, `.failure`, `.hang` — which is how the 25-deep tool chain,
    concurrency, recovery, retry and cancellation tests run on a Mac in milliseconds. It lives in `Tests/`, not in the
    products, so your app never ships a scripted model. Copy it into your own test target.
