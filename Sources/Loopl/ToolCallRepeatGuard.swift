import Foundation

/// Blocks a model from re-running a tool call it has **already got a result
/// for** in this conversation.
///
/// Why this exists: runtimes that prompt tools manually (no native tool-call
/// tokens — Apple Foundation Models, Gemma, SmolLM2) feed the tool exchange
/// back as plain text, and a small model may simply echo the call it sees
/// instead of answering. The Strands event loop then does the right thing with
/// the wrong input: it executes the tool a second time and answers twice.
/// The guard makes that impossible at the provider boundary, without touching
/// the loop's semantics — a *different* call, or the same tool with different
/// arguments, always goes through.
///
/// Only calls whose result came back `.success` block a repeat: an errored
/// tool (a timeout, a transient failure) may legitimately be retried.
///
///     let guard = ToolCallRepeatGuard(messages: messages)
///     var gate = ToolCallStreamGate(family: .generic, suppress: { guard.isRepeat($0) })
public struct ToolCallRepeatGuard: Sendable, Hashable {
    /// `name` + canonical input, for every tool use that already has a successful result.
    private let answered: Set<String>

    public init(messages: [Message]) {
        var successfulIds = Set<String>()
        for m in messages where m.role == .user {
            for r in m.toolResults where r.status == .success { successfulIds.insert(r.toolUseId) }
        }
        var keys = Set<String>()
        for m in messages where m.role == .assistant {
            for u in m.toolUses where successfulIds.contains(u.toolUseId) { keys.insert(Self.key(u)) }
        }
        answered = keys
    }

    /// Empty guard (nothing has run yet).
    public init() { answered = [] }

    public var isEmpty: Bool { answered.isEmpty }
    public var count: Int { answered.count }

    /// True when this exact call (same tool, same arguments) already has a successful result.
    public func isRepeat(_ use: ToolUse) -> Bool { answered.contains(Self.key(use)) }

    /// Tool name + a canonical (key-sorted, compact) rendering of the input, so
    /// `{"a":1,"b":2}` and `{"b":2,"a":1}` are the same call.
    static func key(_ use: ToolUse) -> String {
        use.name + "\u{1}" + JSONValue.object(use.input).canonical
    }
}

extension JSONValue {
    /// Key-sorted, whitespace-free rendering — stable enough to compare two tool inputs.
    var canonical: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .string(let s): return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        case .array(let a): return "[" + a.map(\.canonical).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.keys.sorted().map { "\"\($0)\":" + o[$0]!.canonical }.joined(separator: ",") + "}"
        }
    }
}
