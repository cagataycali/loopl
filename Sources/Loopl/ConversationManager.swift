import Foundation

// Strands `agent/conversation_manager/*`.

/// Strands `ConversationManager`. Operates on the message array by value
/// (Swift) where Strands mutates `agent.messages` in place; the agent writes
/// the result back.
public protocol ConversationManager: Sendable {
    /// Strands `apply_management`: after every event-loop run.
    func applyManagement(_ messages: inout [Message])
    /// Strands `reduce_context`: on `ContextWindowOverflowError` (error set) or
    /// proactively (error nil). Throws `ContextWindowOverflowError` when nothing
    /// more can be removed and an overflow error was given.
    func reduceContext(_ messages: inout [Message], error: (any Error)?) throws
    /// Strands `register_hooks` (optional).
    func registerHooks(_ registry: HookRegistry)
}
public extension ConversationManager {
    func registerHooks(_ registry: HookRegistry) {}
}

/// Strands `NullConversationManager`: never trims; an overflow is re-thrown.
public struct NullConversationManager: ConversationManager {
    public init() {}
    public func applyManagement(_ messages: inout [Message]) {}
    public func reduceContext(_ messages: inout [Message], error: (any Error)?) throws {
        if let error { throw error }
    }
}

/// Strands `context_compression.find_valid_trim_point`: the first index ≥
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

/// Strands `SlidingWindowConversationManager`, plus the edge-specific piece the
/// brief asks for: a token-estimate budget. Keeps the last `windowSize`
/// messages (default 40), truncates large tool results first on overflow,
/// trims to a boundary that keeps toolUse/toolResult pairs intact, and — as a
/// `HookProvider` on `BeforeModelCallEvent` — trims proactively when the
/// projected prompt exceeds `compressionThreshold × contextWindow`, so an
/// unlimited loop never overflows the window. That IS the only limiter.
public final class SlidingWindowConversationManager: ConversationManager, HookProvider, @unchecked Sendable {
    public let windowSize: Int
    public let shouldTruncateResults: Bool
    /// Fraction of the context window at which proactive trimming kicks in (Strands default 0.7).
    public let compressionThreshold: Double
    /// Messages at the start of the conversation that are never evicted (Strands `pin_first`).
    public let pinFirst: Int
    public private(set) var removedMessageCount = 0
    private let lock = NSLock()
    static let preserveChars = 200

    public init(windowSize: Int = 40, shouldTruncateResults: Bool = true, compressionThreshold: Double = 0.7, pinFirst: Int = 0) {
        precondition(windowSize >= 0, "windowSize must be non-negative")
        self.windowSize = windowSize; self.shouldTruncateResults = shouldTruncateResults
        self.compressionThreshold = min(1, max(0.05, compressionThreshold)); self.pinFirst = max(0, pinFirst)
    }

    public func registerHooks(_ registry: HookRegistry) {
        registry.addCallback(BeforeModelCallEvent.self) { [self] event in
            // Proactive compression: estimate → trim until under the threshold (or nothing left to trim).
            guard event.contextWindow > 0 else { return }
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
        guard messages.count > windowSize else { return }
        try? reduceContext(&messages, error: nil)
    }

    public func reduceContext(_ messages: inout [Message], error: (any Error)?) throws {
        if windowSize == 0 {
            let pinned = Array(messages.prefix(pinFirst))
            bump(messages.count - pinned.count)
            messages = pinned
            return
        }
        // Reactive overflow: shrink the oldest big tool results first.
        if error != nil, shouldTruncateResults, let idx = oldestMessageWithToolResults(messages), truncateToolResults(&messages, at: idx) {
            return
        }
        let startIndex = messages.count <= windowSize ? 2 : messages.count - windowSize
        var trimIndex = findValidTrimPoint(messages, startIndex: startIndex)
        if trimIndex >= messages.count {
            if let fallback = toolPairTrimPoint(messages, startIndex: startIndex) {
                trimIndex = fallback
            } else if let error {
                throw ContextWindowOverflowError("Unable to trim conversation context! (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))")
            } else {
                return
            }
        }
        let removable = (0..<trimIndex).filter { $0 >= pinFirst }
        if removable.isEmpty {
            if let error { throw ContextWindowOverflowError("Unable to trim conversation context! (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))") }
            return
        }
        bump(removable.count)
        for i in removable.reversed() { messages.remove(at: i) }
    }

    private func bump(_ n: Int) { lock.lock(); removedMessageCount += n; lock.unlock() }

    /// Strands `_find_tool_pair_trim_point`: an assistant(toolUse) followed by its user(toolResult) is a valid start too.
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

    /// Strands `_truncate_tool_results`: keep the first/last 200 chars of each big result.
    func truncateToolResults(_ messages: inout [Message], at idx: Int) -> Bool {
        guard messages.indices.contains(idx) else { return false }
        var changed = false
        let marker = "... [truncated:"
        messages[idx].content = messages[idx].content.map { block in
            guard var r = block.toolResult else { return block }
            let text = r.content
            let keep = Self.preserveChars
            guard !text.contains(marker), text.count > 2 * keep else { return block }
            let removed = text.count - 2 * keep
            r.content = "\(text.prefix(keep))...\n\n... [truncated: \(removed) chars removed] ...\n\n...\(text.suffix(keep))"
            changed = true
            return .toolResult(r)
        }
        return changed
    }
}
