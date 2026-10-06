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

                    // `current_time("Europe/Istanbul")` as the whole reply: a call written as a
                    // signature. Re-ask once, insisting on the JSON shape; the UI's text is replaced.
                    if built.mode == .call, !attempt.sawToolUse,
                       AppleFMPrompt.pseudoCall(in: attempt.visibleText, toolNames: toolSpecs.map(\.name)) != nil {
                        if attempt.textOpened { continuation.yield(.contentBlockDelta(.textReplace(""))) }
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
        /// The text the UI has (deltas + replaces), after `finish()`.
        var visibleText: String
        var sawToolUse: Bool
        /// A text content block was opened towards the UI during this attempt.
        var textOpened: Bool
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
        var textOpened = false
        var first: Date?

        func classify(_ events: [StreamEvent]) {
            for e in events {
                if case .contentBlockDelta(.text(let t)) = e { visibleText += t }
                if case .contentBlockDelta(.textReplace(let t)) = e { visibleText = t }
                if case .contentBlockStart(.toolUse) = e { sawToolUse = true }
                if case .contentBlockStart(.text) = e { textOpened = true }
            }
        }

        for try await snapshot in session.snapshots(prompt: prompt) {
            try Task.checkCancellation()
            guard snapshot != emitted else { continue }
            if !snapshot.hasPrefix(emitted) {
                // A snapshot that does not extend the previous one (FM revised what it
                // had said). Re-run a fresh gate over the whole snapshot and tell the
                // UI the text is now exactly that — never drop it, never duplicate it.
                var fresh = ToolCallStreamGate(family: .generic, suppress: { guardCopy.isRepeat($0) })
                let replay = fresh.feed(snapshot)
                let wasOpen = gate.isTextBlockOpen
                emitted = snapshot
                gate = fresh
                var replaced: [StreamEvent] = []
                if gate.isTextBlockOpen {
                    if !wasOpen { replaced.append(.contentBlockStart(.text)) }
                    replaced.append(.contentBlockDelta(.textReplace(gate.visibleText)))
                } else if wasOpen {
                    replaced.append(.contentBlockDelta(.textReplace("")))
                }
                for e in replay where !isMessageStart(e) {         // a tool block opening mid-replay is forwarded as-is
                    if case .contentBlockStart(.toolUse) = e { replaced.append(e) }
                }
                visibleText = gate.visibleText
                classify(replaced)
                for e in replaced { emit(e) }
                emit(.metadata(stats))
                continue
            }
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

        let textOpenedLive = gate.isTextBlockOpen          // a text block the UI already has open
        var finishEvents = gate.finish()
        classify(finishEvents)
        if suppressMessageStart { finishEvents.removeAll(where: isMessageStart) }

        // Prose that came WITH a tool call is thinking-out-loud, not the answer (the real answer
        // arrives one cycle later, once the result exists). It was streamed live — so retract it
        // from the text block and keep it as reasoning, exactly where #41 puts it (nothing is
        // lost, nothing is shown twice). Prose alone streams and stays the answer.
        if sawToolUse, !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var rewritten: [StreamEvent] = finishEvents.filter(isMessageStart)
            if textOpenedLive {
                rewritten.append(.contentBlockDelta(.textReplace("")))
                rewritten.append(.contentBlockStop)
            }
            rewritten.append(.contentBlockStart(.reasoning))
            rewritten.append(.contentBlockDelta(.reasoning(visibleText)))
            rewritten.append(.contentBlockStop)
            rewritten += Self.withoutTextBlock(finishEvents, openedLive: textOpenedLive)
            finishEvents = rewritten
            visibleText = ""
        }

        // `{"status": "completed", "message": "…"}` as the whole answer → the sentence inside.
        if !sawToolUse, let prose = AppleFMAnswer.unwrap(visibleText) {
            let stop = finishEvents.last(where: { if case .messageStop = $0 { return true }; return false })
            var rewritten: [StreamEvent] = finishEvents.filter(isMessageStart)
            if !textOpenedLive { rewritten.append(.contentBlockStart(.text)) }
            rewritten.append(.contentBlockDelta(.textReplace(prose)))
            rewritten.append(.contentBlockStop)
            rewritten.append(stop ?? .messageStop(.endTurn))
            finishEvents = rewritten
            visibleText = prose
        }

        let emptyRepeat = !sawToolUse
            && visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !gate.suppressedCalls.isEmpty
        return Attempt(stats: stats, finishEvents: finishEvents, emptyRepeat: emptyRepeat,
                       visibleText: visibleText, sawToolUse: sawToolUse, textOpened: textOpened)
    }

    /// `finish()`'s events minus the text block (its start, deltas and closing stop) and
    /// the messageStart — leaving the tool blocks and the messageStop. When the text block
    /// was opened live, its closer is the first `contentBlockStop` before any block start.
    private nonisolated static func withoutTextBlock(_ events: [StreamEvent], openedLive: Bool) -> [StreamEvent] {
        var out: [StreamEvent] = []
        var inText = openedLive
        for e in events {
            switch e {
            case .messageStart: continue
            case .contentBlockStart(.text): inText = true
            case .contentBlockDelta(.text), .contentBlockDelta(.textReplace): continue
            case .contentBlockStop where inText: inText = false
            case .contentBlockStart: inText = false; out.append(e)
            default: out.append(e)
            }
        }
        return out
    }

    private nonisolated func isMessageStart(_ e: StreamEvent) -> Bool {
        if case .messageStart = e { return true }
        return false
    }
}
