import Foundation

// `agent/conversation_manager/*`.

/// `ConversationManager`. Operates on the message array by value
/// (Swift) instead of mutating `agent.messages` in place; the agent writes
/// the result back.
public protocol ConversationManager: Sendable {
    /// `apply_management`: after every event-loop run.
    func applyManagement(_ messages: inout [Message])
    /// `reduce_context`: on `ContextWindowOverflowError` (error set) or
    /// proactively (error nil). Throws `ContextWindowOverflowError` when nothing
    /// more can be removed and an overflow error was given.
    func reduceContext(_ messages: inout [Message], error: (any Error)?) throws
    /// `register_hooks` (optional).
    func registerHooks(_ registry: HookRegistry)
}
public extension ConversationManager {
    func registerHooks(_ registry: HookRegistry) {}
}

/// `NullConversationManager`: never trims; an overflow is re-thrown.
public struct NullConversationManager: ConversationManager {
    public init() {}
    public func applyManagement(_ messages: inout [Message]) {}
    public func reduceContext(_ messages: inout [Message], error: (any Error)?) throws {
        if let error { throw error }
    }
}

/// `context_compression.find_valid_trim_point`: the first index ≥
/// `startIndex` that is a plain user message (no toolResult), so the kept
/// tail starts with a user turn and no toolUse is orphaned from its result.
public func findValidTrimPoint(_ messages: [Message], startIndex: Int) -> Int {
    var i = max(0, startIndex)
    while i < messages.count {
        let m = messages[i]
        if m.role != .user { i += 1; continue }
        if m.hasToolResult { i += 1; continue }
        break
    }
    return i
}

/// `SlidingWindowConversationManager`, plus the edge-specific piece
/// loopl needs: the window is sized from the **runtime's** context window, not
/// from a constant. Apple Foundation Models offers 4096 tokens; an MLX or GGUF
/// Qwen3 offers 8k–32k. One manager serves all of them because it asks the
/// model (through `BeforeModelCallEvent.contextWindow`) how much room there is.
///
/// Trim order (fattest and least needed verbatim first):
/// 1. the oldest oversized **tool result** is truncated to its head+tail,
/// 2. then the oldest turns slide out, never the system prompt (which is not in
///    `messages` at all) and never the current user turn,
/// 3. as a last resort tool results are truncated much harder,
/// 4. only then does an overflow error propagate.
///
/// As a `HookProvider` on `BeforeModelCallEvent` it also trims *proactively*
/// when the projected prompt exceeds `compressionThreshold × contextWindow`, so
/// an unlimited loop never walks into the window. That IS the only limiter.
///
/// Every token number here is the chars/4 **estimate** (`TokenEstimator`), not
/// a tokenizer count — the threshold default of 0.7 is the slack that buys.
public final class SlidingWindowConversationManager: ConversationManager, HookProvider, @unchecked Sendable {
    /// Upper bound on kept messages — the window never grows past this even on
    /// a 128k model (default 40).
    public let windowSize: Int
    public let shouldTruncateResults: Bool
    /// Fraction of the context window at which proactive trimming kicks in (default 0.7).
    public let compressionThreshold: Double
    /// Messages at the start of the conversation that are never evicted (`pin_first`).
    public let pinFirst: Int
    /// Estimated history cost of one message, used to turn a context window
    /// into a message count. 256 ≈ a short turn plus one tool result after
    /// truncation (chars/4 estimate).
    public let tokensPerMessage: Int
    public private(set) var removedMessageCount = 0
    public private(set) var truncatedResultCount = 0
    /// The runtime's window as last reported by `BeforeModelCallEvent`
    /// (0 = not seen yet → `windowSize` is used as-is).
    public private(set) var contextWindow = 0
    private let lock = NSLock()
    static let preserveChars = 200
    static let minPreserveChars = 48
    static let minWindowSize = 4

    public init(windowSize: Int = 40, shouldTruncateResults: Bool = true, compressionThreshold: Double = 0.7, pinFirst: Int = 0, tokensPerMessage: Int = 256) {
        precondition(windowSize >= 0, "windowSize must be non-negative")
        self.windowSize = windowSize; self.shouldTruncateResults = shouldTruncateResults
        self.compressionThreshold = min(1, max(0.05, compressionThreshold)); self.pinFirst = max(0, pinFirst)
        self.tokensPerMessage = max(16, tokensPerMessage)
    }

    /// How many messages fit a given context window: `threshold × ctx /
    /// tokensPerMessage`, clamped to `minWindowSize…windowSize`. `ctx <= 0`
    /// (unknown runtime) falls back to `windowSize`.
    public func windowSize(forContextWindow ctx: Int) -> Int {
        guard ctx > 0 else { return windowSize }
        let budget = Int(Double(ctx) * compressionThreshold)
        return max(Self.minWindowSize, min(windowSize, budget / tokensPerMessage))
    }

    /// The window in force right now (sized from the last seen runtime window).
    public var effectiveWindowSize: Int {
        lock.lock(); let ctx = contextWindow; lock.unlock()
        return windowSize == 0 ? 0 : windowSize(forContextWindow: ctx)
    }

    /// Estimated token budget the proactive pass trims to (0 = unknown window).
    public var tokenBudget: Int {
        lock.lock(); let ctx = contextWindow; lock.unlock()
        return ctx > 0 ? Int(Double(ctx) * compressionThreshold) : 0
    }

    public func registerHooks(_ registry: HookRegistry) {
        registry.addCallback(BeforeModelCallEvent.self) { [self] event in
            // Proactive compression: estimate → trim until under the threshold (or nothing left to trim).
            guard event.contextWindow > 0 else { return }
            self.learn(contextWindow: event.contextWindow)
            let limit = Int(Double(event.contextWindow) * self.compressionThreshold)
            // The fixed part (system prompt + tool specs) is whatever the estimate held beyond the messages.
            let messagesTokens = { (m: [Message]) in m.reduce(0) { $0 + TokenEstimator.estimate($1) } }
            let fixed = max(0, event.projectedInputTokens - messagesTokens(event.messages))
            var projected = event.projectedInputTokens
            var guardCount = 0
            while projected > limit, event.messages.count > 1, guardCount < 1000 {
                let before = event.messages
                try? self.reduceContext(&event.messages, error: nil)
                if event.messages == before { break }   // nothing more to remove
                projected = fixed + messagesTokens(event.messages)
                guardCount += 1
            }
        }
    }

    public func applyManagement(_ messages: inout [Message]) {
        guard messages.count > effectiveWindowSize else { return }
        try? reduceContext(&messages, error: nil)
    }

    public func reduceContext(_ messages: inout [Message], error: (any Error)?) throws {
        let window = effectiveWindowSize
        if window == 0 {
            let pinned = Array(messages.prefix(pinFirst))
            bump(messages.count - pinned.count)
            messages = pinned
            return
        }
        // 1. The fattest, least-needed-verbatim content first: oldest big tool result.
        if shouldTruncateResults, truncateOldestToolResult(&messages, keep: Self.preserveChars) { return }
        // 2. Then the oldest turns slide out.
        if dropOldestTurns(&messages, window: window) { return }
        // 3. Last resort before failing: truncate tool results much harder.
        if shouldTruncateResults, truncateOldestToolResult(&messages, keep: Self.minPreserveChars) { return }
        if let error {
            throw ContextWindowOverflowError("Unable to trim conversation context! (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))")
        }
    }

    private func learn(contextWindow ctx: Int) { lock.lock(); contextWindow = ctx; lock.unlock() }
    private func bump(_ n: Int) { lock.lock(); removedMessageCount += n; lock.unlock() }
    private func bumpTruncated() { lock.lock(); truncatedResultCount += 1; lock.unlock() }

    /// The current user turn: the newest plain user message (a tool-result
    /// message is not one). It is never dropped — mid-tool-loop that is the
    /// question being answered — so the kept history always starts with it.
    /// The system prompt is not part of `messages` and so cannot be dropped at all.
    func currentUserTurnIndex(_ messages: [Message]) -> Int? {
        for (i, m) in messages.enumerated().reversed() where m.role == .user && !m.hasToolResult { return i }
        return nil
    }

    @discardableResult
    func dropOldestTurns(_ messages: inout [Message], window: Int) -> Bool {
        let startIndex = messages.count <= window ? 2 : messages.count - window
        var trimIndex = findValidTrimPoint(messages, startIndex: startIndex)
        if trimIndex >= messages.count {
            guard let fallback = toolPairTrimPoint(messages, startIndex: startIndex) else { return false }
            trimIndex = fallback
        }
        let keep = currentUserTurnIndex(messages)
        let removable = (0..<trimIndex).filter { $0 >= pinFirst && $0 != keep }
        guard !removable.isEmpty else { return false }
        bump(removable.count)
        for i in removable.reversed() { messages.remove(at: i) }
        return true
    }

    /// `_find_tool_pair_trim_point`: an assistant(toolUse) followed by its user(toolResult) is a valid start too.
    func toolPairTrimPoint(_ messages: [Message], startIndex: Int) -> Int? {
        var i = max(0, startIndex)
        while i < messages.count {
            if messages[i].hasToolUse, i + 1 < messages.count, messages[i + 1].role == .user, messages[i + 1].hasToolResult { return i }
            i += 1
        }
        return nil
    }

    func oldestMessageWithToolResults(_ messages: [Message]) -> Int? {
        for (i, m) in messages.enumerated() where i >= pinFirst && m.hasToolResult { return i }
        return nil
    }

    /// Walks from the oldest message and truncates the first tool result that
    /// `keep` actually shrinks (so repeated calls make progress and then move
    /// on). Tool results in the current turn are truncated too — a fat result
    /// is the usual reason a 4096-token window overflows — but never dropped.
    @discardableResult
    func truncateOldestToolResult(_ messages: inout [Message], keep: Int) -> Bool {
        for i in messages.indices where i >= pinFirst && messages[i].hasToolResult {
            if truncateToolResults(&messages, at: i, keep: keep) { return true }
        }
        return false
    }

    /// `_truncate_tool_results`: keep the first/last `keep` chars of
    /// each big result. Monotone — a result is only rewritten when that makes
    /// it meaningfully shorter, so calling this repeatedly terminates.
    @discardableResult
    func truncateToolResults(_ messages: inout [Message], at idx: Int, keep: Int = SlidingWindowConversationManager.preserveChars) -> Bool {
        guard messages.indices.contains(idx) else { return false }
        var changed = false
        messages[idx].content = messages[idx].content.map { block in
            guard var r = block.toolResult else { return block }
            let text = r.content
            guard text.count > 2 * keep else { return block }
            let removed = text.count - 2 * keep
            let candidate = "\(text.prefix(keep))...\n\n... [truncated: \(removed) chars removed] ...\n\n...\(text.suffix(keep))"
            guard candidate.count + 8 < text.count else { return block }
            r.content = candidate
            changed = true
            return .toolResult(r)
        }
        if changed { bumpTruncated() }
        return changed
    }
}
