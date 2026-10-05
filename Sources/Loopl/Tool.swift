import Foundation

/// A tool the agent may call (Strands: `Tool`). `parameters` is a JSON Schema object.
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    func call(_ args: [String: JSONValue]) async throws -> String
}

public struct ToolError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What a tool run produced (Strands: `ToolResult`).
public struct ToolResult: Sendable, Hashable, Identifiable {
    public var id: String { callId }
    public var callId: String
    public var name: String
    public var content: String
    public var isError: Bool
    public var durationMs: Double
    public init(callId: String, name: String, content: String, isError: Bool, durationMs: Double) {
        self.callId = callId; self.name = name; self.content = content; self.isError = isError; self.durationMs = durationMs
    }
    public var message: Message { .tool(result: content, callId: callId, name: name) }
}

extension Tool {
    /// OpenAI-style function spec — the shape HF chat templates understand.
    public var spec: JSONValue {
        .object(["type": "function",
                 "function": .object(["name": .string(name), "description": .string(description), "parameters": parameters])])
    }
}

/// Tool specs as `[[String: Any]]` for `applyChatTemplate(messages:tools:)`.
public func toolSpecs(_ tools: [any Tool]) -> [[String: any Sendable]] {
    tools.map { ($0.spec.anyValue as? [String: any Sendable]) ?? [:] }
}

/// Build a JSON-schema `parameters` object with less typing:
/// `ToolSchema.object(["expression": .string("e.g. 23*47")], required: ["expression"])`.
public enum ToolSchema {
    public static func object(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": "object", "properties": .object(props), "required": .array(required.map(JSONValue.string))])
    }
    public static func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    public static func number(_ description: String) -> JSONValue { ["type": "number", "description": .string(description)] }
    public static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }
}

/// A tool from a closure — for showcases and tests.
public struct ClosureTool: Tool {
    public let name: String
    public let description: String
    public let parameters: JSONValue
    let body: @Sendable ([String: JSONValue]) async throws -> String
    public init(name: String, description: String, parameters: JSONValue = ToolSchema.object([:]),
                _ body: @Sendable @escaping ([String: JSONValue]) async throws -> String) {
        self.name = name; self.description = description; self.parameters = parameters; self.body = body
    }
    public func call(_ args: [String: JSONValue]) async throws -> String { try await body(args) }
}
