import Foundation

public enum RuntimeKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case mlx        // ml-explore/mlx-swift-lm, Metal, real device only
    case appleFM    // Apple Foundation Models (iOS 26+, Apple Intelligence)
    case gguf       // llama.cpp — v2, stub
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .mlx: "MLX"
        case .appleFM: "Apple Intelligence"
        case .gguf: "llama.cpp (GGUF)"
        }
    }
}

public struct GenerationParams: Sendable, Hashable {
    public var temperature: Float = 0.6
    public var topP: Float = 0.95
    public var maxTokens: Int = 1024
    /// Hard context window the runtime should budget for (KV cache).
    public var contextLength: Int = 4096
    public init() {}
}

/// Live numbers for the HUD — every one measured, none estimated (Apple FM
/// token counts are labelled as estimates by that runtime).
public struct Metrics: Sendable, Hashable {
    public var promptTokens: Int = 0
    public var generatedTokens: Int = 0
    /// Milliseconds from `stream()` call to the first visible token.
    public var ttftMs: Double = 0
    /// Decode speed (generated tokens / generation seconds), excluding prefill.
    public var tokensPerSecond: Double = 0
    public var contextUsed: Int = 0
    public var contextMax: Int = 0
    public var finished = false
    public var stopReason: String = ""
    public var estimated = false
    public init() {}
}

/// What a model streams back. `.toolCall` is for runtimes that detect calls
/// natively (MLX's tool-call policy, Foundation Models' Tool); text-only
/// runtimes just stream `.text` and the agent parses it.
public enum ModelEvent: Sendable {
    case text(String)
    case toolCall(ToolCall)
    case metrics(Metrics)
}

public struct ModelError: LocalizedError, Sendable {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// The one contract every engine implements (Strands: `Model`). Models are
/// actors — weights must never be touched from two tasks.
public protocol Model: Actor {
    nonisolated var kind: RuntimeKind { get }
    var loadedModelId: String? { get }
    /// `progress` is 0…1 for weight loading (download is the model manager's job).
    func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws
    nonisolated func stream(messages: [Message], tools: [any Tool], params: GenerationParams) -> AsyncThrowingStream<ModelEvent, Error>
    func unload() async
    /// Whether this runtime can run at all on this build/device (Metal, OS version…).
    nonisolated static func availability() -> RuntimeAvailability
}

public struct RuntimeAvailability: Sendable, Hashable {
    public var available: Bool
    public var reason: String
    public static let ok = RuntimeAvailability(available: true, reason: "")
    public init(available: Bool, reason: String) { self.available = available; self.reason = reason }
}
