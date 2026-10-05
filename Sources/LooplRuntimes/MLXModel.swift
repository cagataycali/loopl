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
    public private(set) var params = GenerationParams()
    private var container: ModelContainer?
    private var spec: ModelSpec?

    public init() {}
    public func updateConfig(_ params: GenerationParams) { self.params = params }

    public nonisolated static func availability() -> RuntimeAvailability { .ok }

    public func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        guard let directory else { throw ModelError("\(spec.name) is not downloaded") }
        await unload()
        progress(0.05)
        MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)
        let c = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        container = c
        self.spec = spec
        params = spec.defaultParams
        loadedModelId = spec.id
        progress(1)
    }

    public func unload() async {
        container = nil
        spec = nil
        loadedModelId = nil
        MLX.GPU.clearCache()
    }

    private func snapshot() -> (ModelContainer, ModelSpec, GenerationParams)? {
        guard let container, let spec else { return nil }
        return (container, spec, params)
    }

    /// Strands `Model.stream`: prompt → MLX decode → `StreamEvent`s. Tool-call
    /// markup is resolved here (provider side) by `ToolCallStreamGate`; MLX's
    /// own native tool-call detection is merged in when it fires.
    public nonisolated func stream(_ messages: [Loopl.Message], toolSpecs: [Loopl.ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let (container, spec, params) = await self.snapshot() else { throw ModelError("no model loaded") }
                    let started = Date()
                    var stats = Metrics()
                    stats.contextMax = params.contextLength

                    let specDicts = toolSpecs.templateDictionaries
                    let prompt: [Int] = try await container.perform { context in
                        try PromptEncoder.encode(systemPrompt: systemPrompt, messages: messages, toolSpecs: toolSpecs, family: spec.family,
                                                 kwargs: spec.chatTemplateKwargs?.mapValues { $0.anyValue }, tokenizer: context.tokenizer)
                    }
                    // Strands ContextWindowOverflowException analogue: the prompt alone does not fit.
                    if prompt.count >= params.contextLength - 16 {
                        throw ContextWindowOverflowError("prompt is \(prompt.count) tokens; context window is \(params.contextLength)")
                    }
                    stats.promptTokens = prompt.count
                    stats.contextUsed = prompt.count
                    continuation.yield(.metadata(stats))

                    // nil maxTokens → generate until EOS or the window is full.
                    let budget = params.maxTokens ?? max(1, params.contextLength - prompt.count - 1)
                    let gp = GenerateParameters(maxTokens: budget, maxKVSize: params.contextLength, temperature: params.temperature, topP: params.topP)

                    let gen: AsyncStream<Generation> = try await container.perform { context in
                        let input = LMInput(tokens: MLXArray(prompt))
                        return try MLXLMCommon.generate(input: input, parameters: gp, context: context, tools: specDicts.isEmpty ? nil : specDicts)
                    }

                    var gate = ToolCallStreamGate(family: spec.family)
                    var native: [ToolUse] = []
                    var firstToken: Date?
                    var chunks = 0
                    var hitBudget = false
                    for await g in gen {
                        try Task.checkCancellation()
                        switch g {
                        case .chunk(let s):
                            if firstToken == nil { firstToken = Date(); stats.ttftMs = firstToken!.timeIntervalSince(started) * 1000 }
                            chunks += 1
                            stats.generatedTokens = chunks               // live: 1 chunk ≈ 1 token; exact count arrives in .info
                            stats.contextUsed = prompt.count + chunks
                            if let ft = firstToken { let dt = Date().timeIntervalSince(ft); if dt > 0.05 { stats.tokensPerSecond = Double(chunks) / dt } }
                            for ev in gate.feed(s) { continuation.yield(ev) }
                            continuation.yield(.metadata(stats))
                        case .toolCall(let call):
                            let args = call.function.arguments.mapValues { Loopl.JSONValue(any: $0.sendableAny) }
                            native.append(ToolUse(toolUseId: call.id ?? ToolUse.makeId(), name: call.function.name, input: args))
                        case .rejectedToolCall:
                            break   // the gate still sees the raw text and parses it itself
                        case .info(let info):
                            stats.promptTokens = info.promptTokenCount
                            stats.generatedTokens = info.generationTokenCount
                            stats.contextUsed = info.promptTokenCount + info.generationTokenCount
                            stats.tokensPerSecond = info.generateTime > 0 ? Double(info.generationTokenCount) / info.generateTime : stats.tokensPerSecond
                            let reason = String(describing: info.stopReason)
                            stats.stopReason = reason
                            hitBudget = reason.lowercased().contains("max")
                        }
                    }
                    stats.finished = true
                    continuation.yield(.metadata(stats))
                    for ev in gate.finish(stopReason: hitBudget ? .maxTokens : .endTurn, native: native) { continuation.yield(ev) }
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
    static func encode(systemPrompt: String?, messages: [Loopl.Message], toolSpecs: [Loopl.ToolSpec], family: ToolFamily, kwargs: [String: any Sendable]?, tokenizer: any MLXLMCommon.Tokenizer) throws -> [Int] {
        let specs = toolSpecs.templateDictionaries
        // 1. Native template with tools (Qwen3, Llama 3.x, Phi-4, SmolLM3…).
        if !toolSpecs.isEmpty, let ids = try? tokenizer.applyChatTemplate(messages: Loopl.Message.templateDictionaries(systemPrompt: systemPrompt, messages: messages), tools: specs, additionalContext: kwargs) { return ids }
        // 2. Template without tools: inject the manual spec into the system prompt, fold tool turns.
        let folded = PromptBuilder.foldToolMessages(messages)
        let sys = PromptBuilder.toolSystemPrompt(toolSpecs: toolSpecs, family: family, base: systemPrompt)
        if let ids = try? tokenizer.applyChatTemplate(messages: Loopl.Message.templateDictionaries(systemPrompt: sys.isEmpty ? nil : sys, messages: folded), tools: nil, additionalContext: kwargs) { return ids }
        // 3. Gemma-style templates reject a system role: merge it into the first user turn.
        if !sys.isEmpty, let first = folded.first, first.role == .user {
            var merged = folded; merged[0] = .user(sys + "\n\n" + first.text)
            if let ids = try? tokenizer.applyChatTemplate(messages: Loopl.Message.templateDictionaries(systemPrompt: nil, messages: merged), tools: nil, additionalContext: kwargs) { return ids }
        }
        // 4. No template at all: ChatML text.
        return tokenizer.encode(text: PromptBuilder.chatML(systemPrompt: sys.isEmpty ? nil : sys, messages: folded), addSpecialTokens: false)
    }
}
#else
/// Simulator / no-MLX build: the type exists so the UI compiles, but it
/// says so honestly.
public actor MLXModel: Model {
    public nonisolated let kind: RuntimeKind = .mlx
    public private(set) var loadedModelId: String?
    public private(set) var params = GenerationParams()
    public init() {}
    public func updateConfig(_ params: GenerationParams) { self.params = params }
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
    public nonisolated func stream(_ messages: [Loopl.Message], toolSpecs: [Loopl.ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ModelError(Self.availability().reason)) }
    }
}
#endif
