import Foundation

// Strands `types/content.py` + `types/tools.py` (ToolUse / ToolResult), in Swift.
// A conversation is `[Message]`; a message is a role plus content blocks; the
// system prompt is NOT a message (it travels beside the array, as in Strands).

/// Strands `Role` — only user/assistant appear in the message array.
public enum Role: String, Sendable, Codable, Hashable {
    case user, assistant
}

/// Strands `ToolUse`: the model asked for a tool, with JSON input.
public struct ToolUse: Sendable, Hashable, Codable, Identifiable {
    public var toolUseId: String
    public var name: String
    public var input: [String: JSONValue]

    public init(toolUseId: String = ToolUse.makeId(), name: String, input: [String: JSONValue]) {
        self.toolUseId = toolUseId; self.name = name; self.input = input
    }
    public static func makeId() -> String { "tooluse_" + UUID().uuidString.prefix(8).lowercased() }

    public var id: String { toolUseId }
    /// Compatibility spelling from the 0.1 SDK (`ToolCall.arguments`).
    public var arguments: [String: JSONValue] { input }
}

/// 0.1 name. `ToolUse` is the Strands name; this alias goes away in the next commit.
@available(*, deprecated, renamed: "ToolUse")
public typealias ToolCall = ToolUse

/// Strands `ToolResult`: what a tool produced for one `ToolUse`.
public struct ToolResult: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable, Hashable { case success, error }
    public var toolUseId: String
    public var name: String
    public var status: Status
    /// Text content. loopl tools return a single string (JSON or prose).
    public var content: String
    /// Wall time of the tool call, for the UI; not part of what the model sees.
    public var durationMs: Double

    public init(toolUseId: String, name: String, status: Status = .success, content: String, durationMs: Double = 0) {
        self.toolUseId = toolUseId; self.name = name; self.status = status; self.content = content; self.durationMs = durationMs
    }
    public var id: String { toolUseId }
    public var isError: Bool { status == .error }
    /// 0.1 spelling.
    public var callId: String { toolUseId }

    public static func error(_ toolUse: ToolUse, _ message: String, durationMs: Double = 0) -> ToolResult {
        ToolResult(toolUseId: toolUse.toolUseId, name: toolUse.name, status: .error, content: message, durationMs: durationMs)
    }
}

/// Strands `ContentBlock` — the union of things a message can carry.
public enum ContentBlock: Sendable, Hashable, Codable {
    case text(String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    /// Model "thinking" (Qwen3 `<think>`, reasoning deltas). Kept in history so templates can replay it; UIs may hide it.
    case reasoning(String)

    public var text: String? { if case .text(let s) = self { return s }; return nil }
    public var toolUse: ToolUse? { if case .toolUse(let t) = self { return t }; return nil }
    public var toolResult: ToolResult? { if case .toolResult(let r) = self { return r }; return nil }
    public var isToolUse: Bool { toolUse != nil }
    public var isToolResult: Bool { toolResult != nil }
}

/// Strands `Message`: `{role, content: [ContentBlock]}`.
public struct Message: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var role: Role
    public var content: [ContentBlock]

    public init(id: UUID = UUID(), role: Role, content: [ContentBlock]) {
        self.id = id; self.role = role; self.content = content
    }

    // Convenience constructors (the 0.1 enum cases, as functions).
    public static func user(_ text: String) -> Message { Message(role: .user, content: [.text(text)]) }
    public static func assistant(_ text: String) -> Message { Message(role: .assistant, content: [.text(text)]) }
    public static func assistant(text: String, toolUses: [ToolUse]) -> Message {
        var blocks: [ContentBlock] = text.isEmpty ? [] : [.text(text)]
        blocks += toolUses.map(ContentBlock.toolUse)
        return Message(role: .assistant, content: blocks)
    }
    /// The user turn that carries tool results back to the model (Strands: `{"role": "user", "content": [{"toolResult": …}]}`).
    public static func toolResults(_ results: [ToolResult]) -> Message {
        Message(role: .user, content: results.map(ContentBlock.toolResult))
    }

    /// All text blocks joined (Strands `AgentResult.__str__` semantics).
    public var text: String { content.compactMap(\.text).joined(separator: "\n") }
    public var reasoning: String { content.compactMap { if case .reasoning(let r) = $0 { return r }; return nil }.joined() }
    public var toolUses: [ToolUse] { content.compactMap(\.toolUse) }
    public var toolResults: [ToolResult] { content.compactMap(\.toolResult) }
    public var hasToolUse: Bool { content.contains { $0.isToolUse } }
    public var hasToolResult: Bool { content.contains { $0.isToolResult } }
    /// 0.1 spelling.
    public var toolCalls: [ToolUse] { toolUses }

    /// Encoding is role + content only (ids are local). Decoding mints a fresh id.
    enum CodingKeys: String, CodingKey { case role, content }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode([ContentBlock].self, forKey: .content)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role); try c.encode(content, forKey: .content)
    }
    public static func == (a: Message, b: Message) -> Bool { a.role == b.role && a.content == b.content }
    public func hash(into h: inout Hasher) { h.combine(role); h.combine(content) }
}

// MARK: - Chat-template rendering (provider side)

extension Message {
    /// OpenAI/HF chat-template shaped dictionaries for one message. A user
    /// message carrying tool results becomes one `tool` message per result —
    /// that is what HF templates (Qwen, Llama 3, SmolLM3) expect.
    public var templateDictionaries: [[String: any Sendable]] {
        switch role {
        case .user:
            if hasToolResult {
                return toolResults.map { r in ["role": "tool", "content": r.content, "tool_call_id": r.toolUseId, "name": r.name] }
            }
            return [["role": "user", "content": text]]
        case .assistant:
            var d: [String: any Sendable] = ["role": "assistant", "content": text]
            let uses = toolUses
            if !uses.isEmpty {
                d["tool_calls"] = uses.map { u -> [String: any Sendable] in
                    ["id": u.toolUseId, "type": "function",
                     "function": ["name": u.name, "arguments": JSONValue.object(u.input).anyValue] as [String: any Sendable]]
                }
            }
            let r = reasoning
            if !r.isEmpty { d["reasoning_content"] = r }
            return [d]
        }
    }

    /// The full template input: system prompt first (if any), then every message.
    public static func templateDictionaries(systemPrompt: String?, messages: [Message]) -> [[String: any Sendable]] {
        var out: [[String: any Sendable]] = []
        if let s = systemPrompt, !s.isEmpty { out.append(["role": "system", "content": s]) }
        for m in messages { out += m.templateDictionaries }
        return out
    }
}
