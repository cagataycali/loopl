import Foundation
import Loopl

/// Test-only scripted model. Each `stream()` plays the next `Turn`. Lives in
/// Tests/ on purpose: the app ships no demo runtime.
public actor FakeModel: Model {
    public enum Turn: Sendable {
        /// Plain text (word by word) → endTurn.
        case text(String)
        /// Text + native toolUse blocks → toolUse.
        case toolUse(text: String = "", [ToolUse])
        /// Raw text run through `ToolCallStreamGate` (tests the provider-side markup path).
        case markup(String, family: ToolFamily = .hermes)
        /// Partial content then `messageStop(.maxTokens)`.
        case maxTokens(text: String, [ToolUse])
        /// The stream throws this error (before any event).
        case failure(any Error)
        /// Emits `n` text deltas then sleeps forever (for cancellation tests).
        case hang(after: Int)
    }

    public nonisolated let kind: RuntimeKind = .mlx
    public private(set) var loadedModelId: String?
    public private(set) var params = GenerationParams()
    public var turns: [Turn]
    public private(set) var seenPrompts: [[Message]] = []
    public private(set) var seenSystemPrompts: [String?] = []
    public private(set) var seenToolSpecs: [[ToolSpec]] = []
    public var fallback: Turn = .text("(script exhausted)")
    /// Optional: pick the turn from the request itself (system prompt + messages) instead of the queue — for tests where
    /// several agents share one model and the ORDER of their calls is not deterministic.
    public var chooser: (@Sendable (_ system: String?, _ messages: [Message]) -> Turn)?
    public func setChooser(_ f: (@Sendable (String?, [Message]) -> Turn)?) { chooser = f }
    public nonisolated let delayPerChunkNs: UInt64

    public init(turns: [Turn], contextLength: Int = 8192, delayPerChunkNs: UInt64 = 0) {
        self.turns = turns
        self.delayPerChunkNs = delayPerChunkNs
        params.contextLength = contextLength
    }
    /// Legacy convenience: scripts are raw text run through the markup gate.
    public init(scripts: [String], family: ToolFamily = .hermes) {
        self.init(turns: scripts.map { .markup($0, family: family) })
    }

    public nonisolated static func availability() -> RuntimeAvailability { .ok }
    public func updateConfig(_ params: GenerationParams) { self.params = params }
    /// Queue more turns on a model the agent already holds (multi-invocation tests).
    public func appendTurns(_ more: [Turn]) { turns.append(contentsOf: more) }
    public func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        loadedModelId = spec.id; progress(1)
    }
    public func unload() async { loadedModelId = nil }

    private func next(_ messages: [Message], _ specs: [ToolSpec], _ system: String?) -> Turn {
        seenPrompts.append(messages); seenToolSpecs.append(specs); seenSystemPrompts.append(system)
        if let chooser { return chooser(system, messages) }
        guard !turns.isEmpty else { return fallback }
        return turns.removeFirst()
    }

    public nonisolated func stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let turn = await self.next(messages, toolSpecs, systemPrompt)
                let ctx = await self.params.contextLength
                var m = Metrics(); m.contextMax = ctx; m.estimated = true
                m.promptTokens = TokenEstimator.estimate(messages: messages, systemPrompt: systemPrompt, toolSpecs: toolSpecs)
                // Overflow analogue: the prompt does not fit the configured window.
                if m.promptTokens >= ctx { continuation.finish(throwing: ContextWindowOverflowError("fake: \(m.promptTokens) ≥ \(ctx)")); return }
                do {
                    switch turn {
                    case .failure(let e):
                        throw e
                    case .text(let t):
                        continuation.yield(.messageStart(role: .assistant))
                        try await self.emitText(t, &m, continuation)
                        continuation.yield(.messageStop(.endTurn))
                    case .toolUse(let t, let uses):
                        continuation.yield(.messageStart(role: .assistant))
                        if !t.isEmpty { try await self.emitText(t, &m, continuation) }
                        for u in uses {
                            continuation.yield(.contentBlockStart(.toolUse(toolUseId: u.toolUseId, name: u.name)))
                            let json = JSONValue.object(u.input).compact
                            let mid = json.index(json.startIndex, offsetBy: json.count / 2)
                            continuation.yield(.contentBlockDelta(.toolUse(input: String(json[..<mid]))))
                            continuation.yield(.contentBlockDelta(.toolUse(input: String(json[mid...]))))
                            continuation.yield(.contentBlockStop)
                        }
                        continuation.yield(.messageStop(.toolUse))
                    case .markup(let raw, let family):
                        var gate = ToolCallStreamGate(family: family)
                        for piece in Self.pieces(raw) {
                            if self.delayPerChunkNs > 0 { try await Task.sleep(nanoseconds: self.delayPerChunkNs) }
                            try Task.checkCancellation()
                            for ev in gate.feed(piece) { continuation.yield(ev) }
                        }
                        for ev in gate.finish() { continuation.yield(ev) }
                    case .maxTokens(let t, let uses):
                        continuation.yield(.messageStart(role: .assistant))
                        if !t.isEmpty { try await self.emitText(t, &m, continuation) }
                        for u in uses {
                            continuation.yield(.contentBlockStart(.toolUse(toolUseId: u.toolUseId, name: u.name)))
                            continuation.yield(.contentBlockDelta(.toolUse(input: String(JSONValue.object(u.input).compact.dropLast(3)))))   // cut off
                            continuation.yield(.contentBlockStop)
                        }
                        continuation.yield(.messageStop(.maxTokens))
                    case .hang(let n):
                        continuation.yield(.messageStart(role: .assistant))
                        continuation.yield(.contentBlockStart(.text))
                        for i in 0..<n { continuation.yield(.contentBlockDelta(.text("w\(i) "))) }
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                    m.finished = true
                    continuation.yield(.metadata(m))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func pieces(_ s: String) -> [String] {
        // ~4-char pieces so openers like "<tool_call>" straddle chunk boundaries (the gate must cope).
        var out: [String] = []; var cur = ""
        for ch in s { cur.append(ch); if cur.count >= 4 { out.append(cur); cur = "" } }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func emitText(_ t: String, _ m: inout Metrics, _ c: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        c.yield(.contentBlockStart(.text))
        var n = 0
        for word in t.split(separator: " ", omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            if delayPerChunkNs > 0 { try await Task.sleep(nanoseconds: delayPerChunkNs) }
            n += 1
            c.yield(.contentBlockDelta(.text((n == 1 ? "" : " ") + String(word))))
        }
        m.generatedTokens = n; m.contextUsed = m.promptTokens + n
        c.yield(.contentBlockStop)
    }
}
