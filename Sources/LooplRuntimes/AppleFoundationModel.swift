import Foundation
import Loopl
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Foundation Models (iOS 26+). ~3B on-device model, zero download,
/// 4096-token window. Tool calls: we prompt manually (`generic` family) and
/// parse — the native `Tool` protocol needs compile-time typed arguments,
/// which does not fit a runtime-defined toolset; noted in README as v2.
public actor AppleFoundationModel: Model {
    public nonisolated let kind: RuntimeKind = .appleFM
    public private(set) var loadedModelId: String?
    public private(set) var params = GenerationParams()
    public init() {}
    public func updateConfig(_ params: GenerationParams) { self.params = params }

    public nonisolated static func availability() -> RuntimeAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ok
            case .unavailable(let reason):
                let why: String
                switch reason {
                case .deviceNotEligible: why = "device not eligible for Apple Intelligence"
                case .appleIntelligenceNotEnabled: why = "Apple Intelligence is off — Settings › Apple Intelligence & Siri"
                case .modelNotReady: why = "model not ready (still downloading / device busy)"
                @unknown default: why = "unavailable: \(String(describing: reason))"
                }
                return RuntimeAvailability(available: false, reason: why)
            @unknown default:
                return RuntimeAvailability(available: false, reason: "unknown availability")
            }
        }
        return RuntimeAvailability(available: false, reason: "needs iOS 26 or later")
        #else
        return RuntimeAvailability(available: false, reason: "FoundationModels framework not in this SDK")
        #endif
    }

    public func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        let a = Self.availability()
        guard a.available else { throw ModelError(a.reason) }
        var p = spec.defaultParams; p.contextLength = min(p.contextLength, 4096); params = p
        loadedModelId = spec.id
        progress(1)
    }

    public func unload() async { loadedModelId = nil }

    public nonisolated func stream(_ messages: [Message], toolSpecs: [Loopl.ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(FoundationModels)
                guard #available(iOS 26, macOS 26, *) else { continuation.finish(throwing: ModelError("needs iOS 26")); return }
                do {
                    let params = await self.params
                    let started = Date()
                    var stats = Metrics()
                    stats.contextMax = 4096
                    // Instructions = system prompt (+ manual tool spec); transcript = the rest, flattened.
                    let turns = PromptBuilder.foldToolMessages(messages)
                    let instructions = PromptBuilder.toolSystemPrompt(toolSpecs: toolSpecs, family: .generic, base: systemPrompt)
                    var prompt = ""
                    for (i, m) in turns.enumerated() {
                        if i == turns.count - 1, m.role == .user { prompt += m.text; break }
                        prompt += "\(m.role == .user ? "User" : "Assistant"): \(m.text)\n"
                    }
                    if turns.last.map({ $0.role != .user }) ?? true { prompt += "Assistant:" }
                    stats.estimated = true
                    stats.promptTokens = (instructions.count + prompt.count) / 4   // estimate: FM exposes no tokenizer; flagged in UI as ≈
                    stats.contextUsed = stats.promptTokens
                    if stats.promptTokens >= 4096 { throw ContextWindowOverflowError("prompt ≈\(stats.promptTokens) tokens; Apple FM window is 4096") }
                    continuation.yield(.metadata(stats))

                    let session = LanguageModelSession(instructions: instructions.isEmpty ? nil : instructions)
                    var options = GenerationOptions()
                    options.temperature = Double(params.temperature)
                    if let mt = params.maxTokens { options.maximumResponseTokens = mt }
                    var gate = ToolCallStreamGate(family: .generic)
                    var emitted = ""
                    var first: Date?
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        let full = snapshot.content
                        guard full.hasPrefix(emitted) else { emitted = full; continue }
                        let delta = String(full.dropFirst(emitted.count))
                        emitted = full
                        if delta.isEmpty { continue }
                        if first == nil { first = Date(); stats.ttftMs = first!.timeIntervalSince(started) * 1000 }
                        stats.generatedTokens = emitted.count / 4
                        stats.contextUsed = stats.promptTokens + stats.generatedTokens
                        if let f = first { let dt = Date().timeIntervalSince(f); if dt > 0.05 { stats.tokensPerSecond = Double(stats.generatedTokens) / dt } }
                        for ev in gate.feed(delta) { continuation.yield(ev) }
                        continuation.yield(.metadata(stats))
                    }
                    stats.finished = true
                    stats.stopReason = "stop"
                    continuation.yield(.metadata(stats))
                    for ev in gate.finish() { continuation.yield(ev) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                #else
                continuation.finish(throwing: ModelError("FoundationModels not available"))
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
