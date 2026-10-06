import Foundation

/// The event loop's only loop detector — and deliberately a narrow one.
///
/// loopl has no iteration cap (Strands has none either). What it refuses is a
/// model asking for the *same tool with the identical input* in two consecutive
/// cycles: that call already has its result one message up, so running it again
/// can only produce the same bytes. Small models do this when they mistake the
/// tool exchange for the thing they are supposed to copy.
///
/// First repeat: the call is not executed; the model gets an error result that
/// says so and asks it to answer. Second repeat (two hits in one invocation):
/// the loop ends with the best text produced so far, so the user gets an answer
/// rather than a spinner. A different tool, or the same tool with different
/// arguments, always goes through — this never counts cycles.
public struct RepeatBreaker: Sendable, Hashable {
    /// How many identical calls were refused in this invocation.
    public private(set) var hits = 0
    /// Refusals before the loop stops with the best text so far.
    public static let maxHits = 2

    public init() {}

    /// Record this cycle's calls against the previous cycle (read from `history`: the
    /// last toolResults message and the assistant turn that asked for them). Returns the
    /// `toolUseId`s that repeat a call whose result the model already has — a successful
    /// one, or one of this breaker's own refusals. An errored call may be retried (a
    /// timeout, a validation complaint the model is fixing), and tools in `exempt`
    /// (those that validate their own input, e.g. structured output) own their retries.
    public mutating func observe(_ uses: [ToolUse], history: [Message], exempt: Set<String> = []) -> Set<String> {
        let answered = Self.answeredKeys(history)
        var repeated = Set<String>()
        for u in uses where !exempt.contains(u.name) && answered.contains(ToolCallRepeatGuard.key(u)) {
            repeated.insert(u.toolUseId)
        }
        hits += repeated.count
        return repeated
    }

    /// Keys of the *previous cycle's* calls whose result stands (success or refusal).
    /// `history` ends with the assistant turn now being executed; the previous cycle is
    /// the toolResults message right before it and the assistant turn that asked for
    /// them. A user question in between means there is no previous cycle.
    static func answeredKeys(_ history: [Message]) -> Set<String> {
        guard history.count >= 3 else { return [] }
        let results = history[history.count - 2], ask = history[history.count - 3]
        guard results.role == .user, results.hasToolResult, ask.role == .assistant, ask.hasToolUse else { return [] }
        let standing = Set(results.toolResults
            .filter { $0.status == .success || $0.content.hasPrefix(Self.refusalPrefix) }
            .map(\.toolUseId))
        return Set(ask.toolUses.filter { standing.contains($0.toolUseId) }.map(ToolCallRepeatGuard.key))
    }

    /// Two refusals in one invocation: stop.
    public var exhausted: Bool { hits >= Self.maxHits }

    static let refusalPrefix = "Already called "

    /// The error result the model sees instead of a second execution.
    public static func result(for use: ToolUse) -> ToolResult {
        .error(use, "\(refusalPrefix)\(use.name) with exactly this input; its result is above. Do not call it again — answer the user with what you have.")
    }

    public static let stopMessage = "the model repeated the same tool call twice after being told its result was already in; ended the turn with the best answer so far"

    /// The text the turn ends with: the latest non-empty assistant text of this
    /// invocation, else the successful tool results, else an honest sentence.
    public func bestText(messages: [Message]) -> String {
        var toolLines: [String] = []
        for m in messages.reversed() {
            switch m.role {
            case .user where m.hasToolResult:
                for r in m.toolResults where r.status == .success { toolLines.append("\(r.name): \(r.content)") }
            case .user:
                return toolLines.isEmpty
                    ? "I could not get further with the tools; please rephrase or ask something else."
                    : toolLines.reversed().joined(separator: "\n")
            case .assistant:
                let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return toolLines.isEmpty ? "No answer was produced." : toolLines.reversed().joined(separator: "\n")
    }
}
