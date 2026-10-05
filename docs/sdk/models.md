# Model protocol

Everything the agent needs from an LLM:

```swift
public protocol Model: Sendable {
    var id: String { get }                       // "mlx-community/Qwen3-1.7B-4bit", "apple.foundation", …
    var capabilities: ModelCapabilities { get }  // nativeTools, contextLength, family

    /// Load weights (download first if needed). Idempotent. Report progress for the UI.
    func load(progress: (@Sendable (DownloadProgress) -> Void)?) async throws
    func unload() async

    /// One model turn. Emit textDelta as tokens arrive, toolUse if the runtime parses calls natively,
    /// then exactly one `.stop`.
    func stream(messages: [Message], tools: [ToolSpec], params: GenerationParams)
        -> AsyncThrowingStream<ModelEvent, Error>

    func tokenCount(_ messages: [Message]) async throws -> Int   // for the context meter
}

public struct ModelCapabilities: Sendable {
    public var family: ToolFamily          // .hermes, .llama3, .gemma, .plainJSON, .native
    public var contextLength: Int          // nominal
    public var usableContext: Int          // what fits on THIS device (memory-bound)
    public var nativeTools: Bool
    public var supportsSystemPrompt: Bool
}
```

## Errors

```swift
public enum ModelError: Error, Sendable {
    case notLoaded
    case unsupportedEnvironment(String)             // simulator for MLX, iOS < 26 for Apple FM
    case unavailable(String)                        // Apple Intelligence off, model downloading by the OS
    case insufficientMemory(needed: Int, available: Int)
    case download(DownloadError)                    // offline, 401 gated, 404, checksum
    case contextExceeded(used: Int, max: Int)
    case gatedRepository(repo: String)              // needs an HF token with access
}
```

`contextExceeded` is thrown *before* generation when `tokenCount` says the prompt will not fit; the app
offers to trim history. Apple Foundation Models reports the same condition as
`GenerationError.exceededContextWindowSize`, which the runtime maps to this case.

## FakeModel

A scripted model for tests and previews. It lives in `Loopl`, so it works on Linux CI.

```swift
let fake = FakeModel(turns: [
    .toolCall("current_time", ["timezone": "Asia/Tokyo"]),
    .text("It is 09:12 in Tokyo.")
])
let agent = Agent(model: fake, tools: [Clock()])
let result = try await agent("time in tokyo?")
XCTAssertEqual(result.iterations, 2)
```

`FakeModel` can also script 20+ consecutive tool calls — that is how the unlimited loop and the loop
detector are tested without a GPU.

## Implementing your own

The contract is small: emit `textDelta`s, emit `toolUse` only if you parse calls yourself (otherwise the
core parser does it from the text by `capabilities.family`), finish with one `.stop`. Honour
`Task.isCancelled` between tokens. See `Sources/LooplRuntimes/MLXModel.swift` for the reference
implementation and `Sources/Loopl/FakeModel.swift` for the minimum viable one.
