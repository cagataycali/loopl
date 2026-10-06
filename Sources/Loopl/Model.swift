import Foundation

public enum RuntimeKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case mlx        // ml-explore/mlx-swift-lm, Metal, real device only
    case appleFM    // Apple Foundation Models (iOS 26+, Apple Intelligence)
    case gguf       // llama.cpp (ggml-org xcframework)
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .mlx: "MLX"
        case .appleFM: "Apple Intelligence"
        case .gguf: "llama.cpp (GGUF)"
        }
    }
}

/// Sampling + context configuration (the provider's `ModelConfig`).
/// Defaults are "maxed out": no new-token cap (`maxTokens == nil` → generate
/// until a stop token or the context is full), context from the catalog.
public struct GenerationParams: Sendable, Hashable, Codable {
    public var temperature: Float = 0.6
    public var topP: Float = 0.95
    public var minP: Float = 0.0
    /// `nil` = until the model stops or the context window is full (the loopl default).
    public var maxTokens: Int? = nil
    /// Hard context window the runtime budgets for (KV cache).
    public var contextLength: Int = 8192
    public var seed: UInt64? = nil
    public init() {}
    public init(temperature: Float = 0.6, topP: Float = 0.95, minP: Float = 0, maxTokens: Int? = nil, contextLength: Int = 8192, seed: UInt64? = nil) {
        self.temperature = temperature; self.topP = topP; self.minP = minP; self.maxTokens = maxTokens; self.contextLength = contextLength; self.seed = seed
    }
}

// MARK: - Errors (`types/exceptions.py`)

/// Generic runtime failure. Not retried.
public struct ModelError: LocalizedError, Sendable {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// `ContextWindowOverflowException`: the prompt does not fit. The agent
/// asks its `ConversationManager` to reduce context and tries again.
public struct ContextWindowOverflowError: LocalizedError, Sendable {
    public let message: String
    public init(_ m: String = "input is too long for the model's context window") { message = m }
    public var errorDescription: String? { message }
}

/// `ModelThrottledException` — the retryable class. On-device: a
/// transient failure (Metal/GPU busy, memory pressure, engine not ready).
public struct ModelThrottledError: LocalizedError, Sendable {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// `MaxTokensReachedException`: the model hit its output limit. The
/// (recovered) partial message is already in `agent.messages`; call again to continue.
public struct MaxTokensReachedError: LocalizedError, Sendable {
    public let message: Message
    public init(message: Message) { self.message = message }
    public var errorDescription: String? {
        "Model stopped generating due to maximum token limit. The partial message has been added to the conversation history. You can continue by calling the agent again."
    }
}

/// `EventLoopException`: wraps any other failure inside a cycle.
public struct EventLoopError: LocalizedError, Sendable {
    public let underlying: String
    public init(_ error: any Error) { underlying = (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
    public var errorDescription: String? { underlying }
}

// MARK: - Model

/// The one contract every engine implements (`Model`).
///
///     func stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error>
///
/// Models are actors — weights must never be touched from two tasks. Text-only
/// engines turn `<tool_call>` markup into `toolUse` blocks themselves (as
/// Bedrock/OpenAI providers do) — see `ToolCallStreamGate`.
public protocol Model: Actor {
    nonisolated var kind: RuntimeKind { get }
    var loadedModelId: String? { get }
    /// Current sampling/context config (`get_config`).
    var params: GenerationParams { get }
    /// `update_config`.
    func updateConfig(_ params: GenerationParams)
    /// `progress` is 0…1 for weight loading (download is the model manager's job).
    func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws
    nonisolated func stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error>
    func unload() async
    /// Whether this runtime can run at all on this build/device (Metal, OS version…).
    nonisolated static func availability() -> RuntimeAvailability
    /// Hard ceiling of the RUNTIME itself, whatever model is loaded: Apple
    /// Foundation Models is fixed at 4096 tokens, MLX/GGUF have none of their
    /// own (the loaded model's config/metadata decides). Default `Int.max`.
    nonisolated static var contextCeiling: Int { get }
    /// The context window to budget against RIGHT NOW: the loaded model's
    /// window clamped by the runtime ceiling. The conversation manager sizes
    /// its sliding window from this — never from a constant.
    var contextWindow: Int { get }
}

public extension Model {
    nonisolated static var contextCeiling: Int { Int.max }
    var contextWindow: Int { min(params.contextLength, Self.contextCeiling) }
}

public struct RuntimeAvailability: Sendable, Hashable {
    public var available: Bool
    public var reason: String
    public static let ok = RuntimeAvailability(available: true, reason: "")
    public init(available: Bool, reason: String) { self.available = available; self.reason = reason }
}

/// Token **estimate** — never a tokenizer count. Everything here is the
/// chars/4 (UTF-8 bytes / 4) heuristic `_estimate_input_tokens` falls
/// back to, plus a few tokens per message for role/separators. It is cheap,
/// runs on every model call, and is deliberately a little pessimistic.
///
/// Real counts exist only where a runtime hands them to us for free (llama.cpp
/// and MLX report `promptTokens` in `Metrics` after tokenising; Apple FM does
/// not, which is why its `Metrics.estimated` flag is set). Budgeting happens
/// BEFORE tokenising, so the budget uses the estimate — that is why the
/// sliding window trims at `compressionThreshold` (0.7) of the window rather
/// than at 100 % of it.
public enum TokenEstimator {
    /// `true` for every number this type produces (see the type's note).
    public static let isEstimate = true

    public static func estimate(_ text: String) -> Int { max(1, (text.utf8.count + 3) / 4) }
    public static func estimate(_ message: Message) -> Int {
        var n = 4   // role + separators
        for b in message.content {
            switch b {
            case .text(let t), .reasoning(let t): n += estimate(t)
            case .toolUse(let u): n += 8 + estimate(u.name) + estimate(JSONValue.object(u.input).compact)
            case .toolResult(let r): n += 8 + estimate(r.content)
            case .image(let i): n += estimate(image: i)
            }
        }
        return n
    }
    /// Vision tokens for one picture. Qwen-VL family: one token per 28×28 patch after the processor
    /// resizes into its budget (≤ 1280 tokens at the default ~1.3 MP ceiling). Unknown size → the ceiling.
    public static func estimate(image: ImageBlock) -> Int {
        guard let px = image.pixelCount else { return 1280 }
        return min(1280, max(16, px / (28 * 28)))
    }
    public static func estimate(messages: [Message], systemPrompt: String?, toolSpecs: [ToolSpec]) -> Int {
        var n = systemPrompt.map(estimate) ?? 0
        n += messages.reduce(0) { $0 + estimate($1) }
        n += toolSpecs.reduce(0) { $0 + estimate($1.openAIFunction.compact) }
        return n
    }
}
