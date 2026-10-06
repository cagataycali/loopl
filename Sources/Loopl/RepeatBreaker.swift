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
    /// Keys of the previous cycle's calls (`name` + canonical input).
    private var previous: Set<String> = []
    /// How many identical calls were refused in this invocation.
    public private(set) var hits = 0
    /// Refusals before the loop stops with the best text so far.
    public static let maxHits = 2

    public init() {}

    /// Record this cycle's calls; returns the `toolUseId`s that repeat the previous cycle verbatim.
    public mutating func observe(_ uses: [ToolUse]) -> Set<String> {
        var repeated = Set<String>()
        var current = Set<String>()
        for u in uses {
            let k = ToolCallRepeatGuard.key(u)
            current.insert(k)
            if previous.contains(k) { repeated.insert(u.toolUseId) }
        }
        hits += repeated.count
        previous = current
        return repeated
    }

    /// Two refusals in one invocation: stop.
    public var exhausted: Bool { hits >= Self.maxHits }

    /// The error result the model sees instead of a second execution.
    public static func result(for use: ToolUse) -> ToolResult {
        .error(use, "\(use.name) was already called with exactly this input and its result is above. Do not call it again; answer the user with what you have.")
    }

    public static let stopMessage = "the model repeated the same tool call twice after being told its result was already in; ended the turn with the best answer so far"

    /// The text the turn ends with: the latest non-empty assistant text of this
    /// invocation, else the successful tool results, else an honest sentence.
    public func bestText(messages: [Message]) -> String {
        // Walk back over this invocation: stop at the user's message that started it.
        var sawAssistant = false
        var toolLines: [String] = []
        for m in messages.reversed() {
            switch m.role {
            case .user where m.hasToolResult:
                for r in m.toolResults where r.status == .success { toolLines.append("\(r.name): \(r.content)") }
            case .user:
                sawAssistant = true          // reached the question → stop
            case .assistant:
                let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            if sawAssistant { break }
        }
        if !toolLines.isEmpty { return toolLines.reversed().joined(separator: "\n") }
        return "I could not get further with the tools; please rephrase or ask something else."
    }
}
