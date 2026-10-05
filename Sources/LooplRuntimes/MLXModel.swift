import Foundation
import Loopl

#if canImport(MLXLLM) && canImport(MLXLMCommon) && !targetEnvironment(simulator)
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import Hub

/// Bridges swift-transformers' tokenizer to MLXLMCommon's `Tokenizer`
/// protocol — the same shape `#adaptHuggingFaceTokenizer` expands to, written
/// out so we do not link MLXHuggingFace (macros + FoundationModels trait).
struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    var hasChatTemplate: Bool { upstream.hasChatTemplate }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        do { return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext) }
        catch Tokenizers.TokenizerError.missingChatTemplate { throw MLXLMCommon.TokenizerError.missingChatTemplate }
    }
}

struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// MLX on Metal. Loads ONLY from a local directory — the model manager owns
/// downloads, so this runtime can never reach the network (the offline proof
/// is structural: there is no URLSession in this file).
public actor MLXModel: Model {
    public nonisolated let kind: RuntimeKind = .mlx
    public private(set) var loadedModelId: String?
    private var container: ModelContainer?
    private var spec: ModelSpec?

    public init() {}

    public nonisolated static func availability() -> RuntimeAvailability { .ok }

    public func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        guard let directory else { throw ModelError("\(spec.name) is not downloaded") }
        await unload()
        progress(0.05)
        MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)
        let c = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        container = c
        self.spec = spec
        loadedModelId = spec.id
        progress(1)
    }

    public func unload() async {
        container = nil
        spec = nil
        loadedModelId = nil
        MLX.GPU.clearCache()
    }

    private func snapshot() -> (ModelContainer, ModelSpec)? {
        guard let container, let spec else { return nil }
        return (container, spec)
    }

    public nonisolated func stream(messages: [Loopl.Message], tools: [any Loopl.Tool], params: GenerationParams) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let (container, spec) = await self.snapshot() else { throw ModelError("no model loaded") }
                    let started = Date()
                    var stats = Metrics()
                    stats.contextMax = params.contextLength

                    let specs = toolSpecs(tools)
                    let prompt: [Int] = try await container.perform { context in
                        try PromptEncoder.encode(messages: messages, tools: tools, specs: specs, family: spec.family, kwargs: spec.chatTemplateKwargs?.mapValues { $0.anyValue }, tokenizer: context.tokenizer)
                    }
                    stats.promptTokens = prompt.count
                    stats.contextUsed = prompt.count
                    continuation.yield(.metrics(stats))

                    let gp = GenerateParameters(maxTokens: params.maxTokens, maxKVSize: params.contextLength, temperature: params.temperature, topP: params.topP)

                    let gen: AsyncStream<Generation> = try await container.perform { context in
                        let input = LMInput(tokens: MLXArray(prompt))
                        return try MLXLMCommon.generate(input: input, parameters: gp, context: context, tools: specs.isEmpty ? nil : specs)
                    }

                    var firstToken: Date?
                    var chunks = 0
                    for await g in gen {
                        try Task.checkCancellation()
                        switch g {
                        case .chunk(let s):
                            if firstToken == nil { firstToken = Date(); stats.ttftMs = firstToken!.timeIntervalSince(started) * 1000 }
                            chunks += 1
                            stats.generatedTokens = chunks               // live: 1 chunk ≈ 1 token; exact count arrives in .info
                            stats.contextUsed = prompt.count + chunks
                            if let ft = firstToken { let dt = Date().timeIntervalSince(ft); if dt > 0.05 { stats.tokensPerSecond = Double(chunks) / dt } }
                            continuation.yield(.text(s))
                            continuation.yield(.metrics(stats))
                        case .toolCall(let call):
                            let args = call.function.arguments.mapValues { Loopl.JSONValue(any: $0.sendableAny) }
                            continuation.yield(.toolCall(Loopl.ToolCall(id: call.id ?? Loopl.ToolCall.makeId(), name: call.function.name, arguments: args)))
                        case .rejectedToolCall(let r):
                            continuation.yield(.text("\n[tool call rejected: \(String(describing: r))]\n"))
                        case .info(let info):
                            stats.promptTokens = info.promptTokenCount
                            stats.generatedTokens = info.generationTokenCount
                            stats.contextUsed = info.promptTokenCount + info.generationTokenCount
                            stats.tokensPerSecond = info.generateTime > 0 ? Double(info.generationTokenCount) / info.generateTime : stats.tokensPerSecond
                            stats.stopReason = String(describing: info.stopReason)
                        }
                    }
                    stats.finished = true
                    continuation.yield(.metrics(stats))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension MLXLMCommon.JSONValue {
    /// Foundation-ish value for re-wrapping into loopl's JSONValue.
    var sendableAny: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .int(let i): i
        case .double(let d): d
        case .string(let s): s
        case .array(let a): a.map(\.sendableAny)
        case .object(let o): o.mapValues(\.sendableAny)
        }
    }
}

/// Chat-template rendering with the right fallbacks, in one place so a
/// unit test can pin it with a fake tokenizer.
enum PromptEncoder {
    static func encode(messages: [Loopl.Message], tools: [any Loopl.Tool], specs: [[String: any Sendable]], family: ToolFamily, kwargs: [String: any Sendable]?, tokenizer: any MLXLMCommon.Tokenizer) throws -> [Int] {
        let dicts = messages.map(\.templateDictionary)
        // 1. Native template with tools (Qwen3, Llama 3.x, Phi-4, SmolLM3…).
        if !tools.isEmpty, let ids = try? tokenizer.applyChatTemplate(messages: dicts, tools: specs, additionalContext: kwargs) { return ids }
        // 2. Template without tools: inject the manual spec into the system prompt, fold tool turns.
        let folded = PromptBuilder.foldToolMessages(messages)
        var withSystem: [Loopl.Message] = folded
        let baseSystem: String? = { if case Loopl.Message.system(let s)? = folded.first { return s }; return nil }()
        let sys = PromptBuilder.toolSystemPrompt(tools: tools, family: family, base: baseSystem)
        if baseSystem != nil { withSystem[0] = Loopl.Message.system(sys) } else if !sys.isEmpty { withSystem.insert(Loopl.Message.system(sys), at: 0) }
        if let ids = try? tokenizer.applyChatTemplate(messages: withSystem.map(\.templateDictionary), tools: nil, additionalContext: kwargs) { return ids }
        // 3. Gemma-style templates reject a system role: merge it into the first user turn.
        if case Loopl.Message.system(let s)? = withSystem.first, withSystem.count > 1, case Loopl.Message.user(let u) = withSystem[1] {
            var merged: [Loopl.Message] = Array(withSystem.dropFirst(2)); merged.insert(Loopl.Message.user(s + "\n\n" + u), at: 0)
            if let ids = try? tokenizer.applyChatTemplate(messages: merged.map(\.templateDictionary), tools: nil, additionalContext: kwargs) { return ids }
        }
        // 4. No template at all: ChatML text.
        return tokenizer.encode(text: PromptBuilder.chatML(withSystem), addSpecialTokens: false)
    }
}
#else
/// Simulator / no-MLX build: the type exists so the UI compiles, but it
/// says so honestly.
public actor MLXModel: Model {
    public nonisolated let kind: RuntimeKind = .mlx
    public private(set) var loadedModelId: String?
    public init() {}
    public nonisolated static func availability() -> RuntimeAvailability {
        #if targetEnvironment(simulator)
        return RuntimeAvailability(available: false, reason: "MLX needs Metal — run on a real iPhone, not the simulator.")
        #else
        return RuntimeAvailability(available: false, reason: "MLX libraries are not linked in this build.")
        #endif
    }
    public func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        throw ModelError(Self.availability().reason)
    }
    public func unload() async {}
    public nonisolated func stream(messages: [Loopl.Message], tools: [any Loopl.Tool], params: GenerationParams) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ModelError(Self.availability().reason)) }
    }
}
#endif
