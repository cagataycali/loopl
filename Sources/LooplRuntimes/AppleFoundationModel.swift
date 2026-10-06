import Foundation
import Loopl

/// Apple Foundation Models (iOS 26+). ~3B on-device model, zero download,
/// 4096-token window. Tool calls are prompted manually (`generic` family) and
/// parsed — the native `FoundationModels.Tool` protocol needs compile-time
/// typed arguments *and* runs its own tool loop inside the session, which would
/// bypass loopl's event loop, its hooks and human-in-the-loop approval.
///
/// The prompt rendering lives in `AppleFMPrompt` and it matters: feeding the
/// tool exchange back in `<tool_call>` markup made FM re-emit the identical
/// call instead of answering (3/3 on real hardware), which the event loop then
/// correctly executed a second time — the "ran the tool twice, answered twice"
/// bug. `ToolCallRepeatGuard` is the belt to that braces: a call that already
/// has a successful result in this conversation can never be issued again, and
/// if suppressing it leaves the turn empty the runtime re-asks once, insisting
/// on plain text.
public actor AppleFoundationModel: Model {
    public nonisolated let kind: RuntimeKind = .appleFM
    /// Apple Foundation Models is a fixed 4096-token window (no config to read).
    public nonisolated static var contextCeiling: Int { 4096 }
    public private(set) var loadedModelId: String?
    public private(set) var params = GenerationParams()
    private nonisolated let factory: any AppleFMSessionFactory

    /// - Parameter sessionFactory: the seam over `LanguageModelSession`. The
    ///   default is the real Apple Intelligence model; tests inject a scripted
    ///   one, because Apple Intelligence exists neither in CI nor in the simulator.
    public init(sessionFactory: any AppleFMSessionFactory = LiveAppleFMSessionFactory()) {
        self.factory = sessionFactory
    }

    public func updateConfig(_ params: GenerationParams) { self.params = params }

    public nonisolated static func availability() -> RuntimeAvailability {
        LiveAppleFMSessionFactory().availability
    }

    /// Availability of *this* instance's backing model (a scripted factory in tests).
    public nonisolated func instanceAvailability() -> RuntimeAvailability { factory.availability }

    public func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        let a = factory.availability
        guard a.available else { throw ModelError(a.reason) }
        var p = spec.defaultParams; p.contextLength = min(p.contextLength, 4096); params = p
        loadedModelId = spec.id
        progress(1)
    }

    public func unload() async { loadedModelId = nil }

    public nonisolated func stream(_ messages: [Message], toolSpecs: [Loopl.ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let params = await self.params
                    let started = Date()
                    var stats = Metrics()
                    stats.contextMax = 4096
                    stats.estimated = true          // FM exposes no tokenizer; the UI shows "≈"

                    let built = AppleFMPrompt.build(messages: messages, toolSpecs: toolSpecs, systemPrompt: systemPrompt)
                    stats.promptTokens = (built.instructions.count + built.prompt.count) / 4
                    stats.contextUsed = stats.promptTokens
                    if stats.promptTokens >= 4096 {
                        throw ContextWindowOverflowError("prompt ≈\(stats.promptTokens) tokens; Apple FM window is 4096")
                    }
                    continuation.yield(.metadata(stats))

                    // A call that already has a successful result can not be issued again.
                    let repeatGuard = ToolCallRepeatGuard(messages: messages)
                    var attempt = try await self.generate(instructions: built.instructions, prompt: built.prompt,
                                                          params: params, repeatGuard: repeatGuard,
                                                          started: started, stats: stats,
                                                          emit: { continuation.yield($0) })
                    stats = attempt.stats

                    // The pathological FM turn: the only thing it produced was a call it
                    // already has the result for. Nothing reached the UI (the gate withholds
                    // tool markup), so drop that turn and re-ask once, insisting on prose.
                    if attempt.emptyRepeat, built.mode == .answer {
                        let insisted = AppleFMPrompt.build(messages: messages, toolSpecs: toolSpecs,
                                                           systemPrompt: systemPrompt, insisting: true)
                        attempt = try await self.generate(instructions: insisted.instructions, prompt: insisted.prompt,
                                                          params: params, repeatGuard: repeatGuard,
                                                          started: started, stats: stats,
                                                          emit: { continuation.yield($0) }, suppressMessageStart: true)
                        stats = attempt.stats
                    }

                    if attempt.emptyRepeat {
                        // Twice in a row (or in `call` mode with nothing else to say): present what
                        // the tools produced rather than recurse for ever or invent a sentence.
                        let results = (messages.last?.toolResults ?? []).map { "\($0.name): \($0.content)" }.joined(separator: "\n")
                        continuation.yield(.contentBlockStart(.text))
                        continuation.yield(.contentBlockDelta(.text(results.isEmpty ? "No answer was produced." : results)))
                        continuation.yield(.contentBlockStop)
                        continuation.yield(.messageStop(.endTurn))
                    } else {
                        for e in attempt.finishEvents { continuation.yield(e) }
                    }

                    stats.finished = true
                    if stats.stopReason.isEmpty { stats.stopReason = "stop" }
                    continuation.yield(.metadata(stats))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - one generation

    private struct Attempt {
        var stats: Metrics
        /// `finish()`'s events, held back so a retried turn can be dropped cleanly.
        var finishEvents: [StreamEvent]
        /// Every tool call this turn produced was a repeat, and it said nothing else.
        var emptyRepeat: Bool
    }

    private func generate(instructions: String, prompt: String, params: GenerationParams,
                          repeatGuard: ToolCallRepeatGuard, started: Date, stats input: Metrics,
                          emit: @Sendable @escaping (StreamEvent) -> Void,
                          suppressMessageStart: Bool = false) async throws -> Attempt {
        var stats = input
        let session = try factory.makeSession(instructions: instructions.isEmpty ? nil : instructions,
                                              temperature: Double(params.temperature),
                                              maxTokens: params.maxTokens)
        let guardCopy = repeatGuard
        var gate = ToolCallStreamGate(family: .generic, suppress: { guardCopy.isRepeat($0) })
        var emitted = ""
        var visibleText = ""
        var sawToolUse = false
        var first: Date?

        func classify(_ events: [StreamEvent]) {
            for e in events {
                if case .contentBlockDelta(.text(let t)) = e { visibleText += t }
                if case .contentBlockStart(.toolUse) = e { sawToolUse = true }
            }
        }

        for try await snapshot in session.snapshots(prompt: prompt) {
            try Task.checkCancellation()
            guard snapshot.hasPrefix(emitted) else { emitted = snapshot; continue }   // non-monotonic snapshot: resync
            let delta = String(snapshot.dropFirst(emitted.count))
            emitted = snapshot
            if delta.isEmpty { continue }
            if first == nil { first = Date(); stats.ttftMs = first!.timeIntervalSince(started) * 1000 }
            stats.generatedTokens = emitted.count / 4
            stats.contextUsed = stats.promptTokens + stats.generatedTokens
            if let f = first { let dt = Date().timeIntervalSince(f); if dt > 0.05 { stats.tokensPerSecond = Double(stats.generatedTokens) / dt } }
            let live = gate.feed(delta)
            classify(live)
            for e in live where !(suppressMessageStart && isMessageStart(e)) { emit(e) }
            emit(.metadata(stats))
        }

        var finishEvents = gate.finish()
        classify(finishEvents)
        if suppressMessageStart { finishEvents.removeAll(where: isMessageStart) }

        let emptyRepeat = !sawToolUse
            && visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !gate.suppressedCalls.isEmpty
        return Attempt(stats: stats, finishEvents: finishEvents, emptyRepeat: emptyRepeat)
    }

    private nonisolated func isMessageStart(_ e: StreamEvent) -> Bool {
        if case .messageStart = e { return true }
        return false
    }
}
