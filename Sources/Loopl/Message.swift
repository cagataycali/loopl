import Foundation

/// One tool invocation the model asked for.
public struct ToolCall: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: [String: JSONValue]

    public init(id: String = ToolCall.makeId(), name: String, arguments: [String: JSONValue]) {
        self.id = id; self.name = name; self.arguments = arguments
    }
    public static func makeId() -> String { "call_" + UUID().uuidString.prefix(8).lowercased() }
}

/// The conversation as the agent loop sees it — the "strands" message array.
public enum Message: Sendable, Hashable, Codable {
    case system(String)
    case user(String)
    case assistant(text: String, toolCalls: [ToolCall])
    case tool(result: String, callId: String, name: String)

    public var role: String {
        switch self {
        case .system: "system"
        case .user: "user"
        case .assistant: "assistant"
        case .tool: "tool"
        }
    }

    public var text: String {
        switch self {
        case .system(let s), .user(let s): s
        case .assistant(let t, _): t
        case .tool(let r, _, _): r
        }
    }

    public var toolCalls: [ToolCall] { if case .assistant(_, let c) = self { return c }; return [] }

    /// OpenAI/HF chat-template shaped dictionary (what `applyChatTemplate` expects).
    public var templateDictionary: [String: any Sendable] {
        switch self {
        case .system(let s): return ["role": "system", "content": s]
        case .user(let s): return ["role": "user", "content": s]
        case .assistant(let text, let calls):
            var d: [String: any Sendable] = ["role": "assistant", "content": text]
            if !calls.isEmpty {
                d["tool_calls"] = calls.map { call -> [String: any Sendable] in
                    ["id": call.id, "type": "function",
                     "function": ["name": call.name, "arguments": JSONValue.object(call.arguments).anyValue] as [String: any Sendable]]
                }
            }
            return d
        case .tool(let result, let callId, let name):
            return ["role": "tool", "content": result, "tool_call_id": callId, "name": name]
        }
    }
}
