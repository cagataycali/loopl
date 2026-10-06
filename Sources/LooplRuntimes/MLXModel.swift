import Foundation
import Loopl

#if canImport(MLXLLM) && canImport(MLXLMCommon) && !targetEnvironment(simulator)
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import Tokenizers
import Hub
import CoreImage

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

/// One generation as the model experienced it (see `MLXModel.setTrace`).
public struct GenerationTrace: Sendable {
    /// The prompt after the chat template, decoded WITH special tokens — what the weights actually read.
    public var prompt: String
    public var promptTokens: Int
    /// Raw decoded output before `ToolCallStreamGate` / `ToolCallParser` touch it.
    public var raw: String
    /// Tool calls mlx-swift-lm's own detector fired on (merged with the parser's).
    public var nativeToolCalls: [String]
    public var stopReason: String?
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
    /// Loaded through `VLMModelFactory` (vision tower present) — prompts go through the model's own processor.
    private var isVLM = false
    private var trace: (@Sendable (GenerationTrace) -> Void)?

    public init() {}
    public func updateConfig(_ params: GenerationParams) { self.params = params }

    /// Observe every generation: the prompt exactly as the model saw it (template applied, special tokens
    /// kept) and the raw decoded text before any tool-call parsing. For audits and self-tests; `nil` = off.
    public func setTrace(_ observer: (@Sendable (GenerationTrace) -> Void)?) { trace = observer }

    public nonisolated static func availability() -> RuntimeAvailability { .ok }

    public func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        guard let directory else { throw ModelError("\(spec.name) is not downloaded") }
        await unload()
        progress(0.05)
        MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)
        // Vision checkpoints (Qwen3-VL, Qwen2.5-VL, Qwen3.5, Gemma 3, SmolVLM…) load through MLXVLM so the
        // vision tower and the image processor come up; text-only ones stay on MLXLLM.
        let c: ModelContainer
        if spec.vision == true {
            c = try await VLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
            isVLM = true
        } else {
            c = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
            isVLM = false
        }
        container = c
        self.spec = spec
        params = spec.defaultParams
        loadedModelId = spec.id
        progress(1)
    }

    public func unload() async {
        container = nil
        spec = nil
        isVLM = false
        loadedModelId = nil
        MLX.GPU.clearCache()
    }

    private func snapshot() -> (ModelContainer, ModelSpec, GenerationParams, Bool, (@Sendable (GenerationTrace) -> Void)?)? {
        guard let container, let spec else { return nil }
        return (container, spec, params, isVLM, trace)
    }

    /// `Model.stream`: prompt → MLX decode → `StreamEvent`s. Tool-call
    /// markup is resolved here (provider side) by `ToolCallStreamGate`; MLX's
    /// own native tool-call detection is merged in when it fires.
    public nonisolated func stream(_ messages: [Loopl.Message], toolSpecs: [Loopl.ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let (container, spec, params, isVLM, trace) = await self.snapshot() else { throw ModelError("no model loaded") }
                    let started = Date()
                    var stats = Metrics()
                    stats.contextMax = params.contextLength

                    let specDicts = toolSpecs.templateDictionaries
                    let kwargs = spec.chatTemplateKwargs?.mapValues { $0.anyValue }
                    let hasImages = messages.contains { $0.hasImage }
                    // Text path: loopl renders the template (fallback chain). Vision path: the checkpoint's own
                    // processor renders it and places the image tokens — images never reach a text model.
                    let promptCount: Int
                    var promptTokens: [Int] = []
                    let gen: AsyncStream<Generation>
                    if isVLM && hasImages {
                        let chat = VisionPrompt.chat(systemPrompt: systemPrompt, messages: messages)
                        let input = UserInput(chat: chat, processing: VisionPrompt.processing, tools: specDicts.isEmpty ? nil : specDicts, additionalContext: kwargs)
                        let lmInput = try await container.prepare(input: input)
                        promptCount = lmInput.text.tokens.size
                        if trace != nil { promptTokens = lmInput.text.tokens.asArray(Int.self) }
                        if promptCount >= params.contextLength - 16 {
                            throw ContextWindowOverflowError("prompt is \(promptCount) tokens (images included); context window is \(params.contextLength)")
                        }
                        stats.promptTokens = promptCount
                        stats.contextUsed = promptCount
                        continuation.yield(.metadata(stats))
                        let budget = params.maxTokens ?? max(1, params.contextLength - promptCount - 1)
                        let gp = GenerateParameters(maxTokens: budget, maxKVSize: params.contextLength, temperature: params.temperature, topP: params.topP)
                        gen = try await container.generate(input: lmInput, parameters: gp, tools: specDicts.isEmpty ? nil : specDicts)
                    } else {
                        let prompt: [Int] = try await container.perform { context in
                            try PromptEncoder.encode(systemPrompt: systemPrompt, messages: messages, toolSpecs: toolSpecs, family: spec.family,
                                                     kwargs: kwargs, tokenizer: context.tokenizer)
                        }
                        // ContextWindowOverflowException analogue: the prompt alone does not fit.
                        if prompt.count >= params.contextLength - 16 {
                            throw ContextWindowOverflowError("prompt is \(prompt.count) tokens; context window is \(params.contextLength)")
                        }
                        promptCount = prompt.count
                        promptTokens = prompt
                        stats.promptTokens = prompt.count
                        stats.contextUsed = prompt.count
                        continuation.yield(.metadata(stats))

                        // nil maxTokens → generate until EOS or the window is full.
                        let budget = params.maxTokens ?? max(1, params.contextLength - prompt.count - 1)
                        let gp = GenerateParameters(maxTokens: budget, maxKVSize: params.contextLength, temperature: params.temperature, topP: params.topP)
                        gen = try await container.perform { context in
                            let input = LMInput(tokens: MLXArray(prompt))
                            return try MLXLMCommon.generate(input: input, parameters: gp, context: context, tools: specDicts.isEmpty ? nil : specDicts)
                        }
                    }
                    let prompt = promptCount

                    var gate = ToolCallStreamGate(family: spec.family)
                    var native: [ToolUse] = []
                    var firstToken: Date?
                    var chunks = 0
                    var hitBudget = false
                    var raw = ""
                    for await g in gen {
                        try Task.checkCancellation()
                        switch g {
                        case .chunk(let s):
                            if trace != nil { raw += s }
                            if firstToken == nil { firstToken = Date(); stats.ttftMs = firstToken!.timeIntervalSince(started) * 1000 }
                            chunks += 1
                            stats.generatedTokens = chunks               // live: 1 chunk ≈ 1 token; exact count arrives in .info
                            stats.contextUsed = prompt + chunks
                            if let ft = firstToken { let dt = Date().timeIntervalSince(ft); if dt > 0.05 { stats.tokensPerSecond = Double(chunks) / dt } }
                            for ev in gate.feed(s) { continuation.yield(ev) }
                            continuation.yield(.metadata(stats))
                        case .toolCall(let call):
                            let args = call.function.arguments.mapValues { Loopl.JSONValue(any: $0.sendableAny) }
                            native.append(ToolUse(toolUseId: call.id ?? ToolUse.makeId(), name: call.function.name, input: args))
                        case .rejectedToolCall(let rejection):
                            // MLXLMCommon's ToolCallProcessor SWALLOWS the raw text of a call it could not
                            // parse (it never reached `.chunk`), so the turn would end silently empty —
                            // measured on Qwen3.5-0.8B, which writes `<function=http>\n<url>\n…\n</parameter>`
                            // (sloppy XML that loopl's parser reads, ToolCallParser/HttpCallShapesTests).
                            // Hand the preview (32 KB bound, whole call in practice) to the gate instead.
                            for ev in gate.feed(rejection.rawTextPreview) { continuation.yield(ev) }
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
                    if let trace {
                        let ids = promptTokens
                        let text = try await container.perform { context in context.tokenizer.decode(tokenIds: ids, skipSpecialTokens: false) }
                        trace(GenerationTrace(prompt: text, promptTokens: promptCount, raw: raw, nativeToolCalls: native.map(\.name), stopReason: stats.stopReason))
                    }
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

/// loopl `Message`s → MLXLMCommon `Chat.Message`s for a vision checkpoint. The model's processor
/// applies the chat template (with `tools`) and swaps each `[{"type":"image"}]` part for the right
/// number of vision tokens. Images are decoded here and downscaled so the longest edge is ≤ 1024 px
/// before the processor's own patch budgeting (Qwen3-VL ≤ 1280 tokens / picture).
enum VisionPrompt {
    static let maxEdge: CGFloat = 1024
    /// Caps the processor's pixel budget at ~1 MP ⇒ ≤ 1280 vision tokens for a 28 px patch (Qwen-VL family).
    static let processing = UserInput.Processing(maxPixels: 1280 * 28 * 28)

    static func chat(systemPrompt: String?, messages: [Loopl.Message]) -> [Chat.Message] {
        var out: [Chat.Message] = []
        if let s = systemPrompt, !s.isEmpty { out.append(.system(s)) }
        for m in messages {
            switch m.role {
            case .user:
                if m.hasToolResult {
                    for r in m.toolResults { out.append(.tool(r.promptContent, id: r.toolUseId, name: r.name)) }
                } else {
                    out.append(.user(m.text, images: m.images.compactMap(image)))
                }
            case .assistant:
                let calls = m.toolUses.map { u in
                    MLXLMCommon.ToolCall(function: .init(name: u.name, arguments: u.input.mapValues { $0.anyValue }), id: u.toolUseId)
                }
                out.append(.assistant(m.text, toolCalls: calls.isEmpty ? nil : calls))
            }
        }
        return out
    }

    /// Decode + downscale. Returns nil for bytes CoreImage cannot read (the turn then goes text-only, honestly).
    static func image(_ block: ImageBlock) -> UserInput.Image? {
        guard var ci = CIImage(data: block.data) else { return nil }
        let w = ci.extent.width, h = ci.extent.height
        let longest = max(w, h)
        if longest > maxEdge, longest > 0 {
            let k = maxEdge / longest
            ci = ci.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        return UserInput.Image.ciImage(ci)
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
