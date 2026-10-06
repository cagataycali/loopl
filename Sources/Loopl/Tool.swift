import Foundation

/// A tool the agent may call (Strands: `AgentTool`). `parameters` is a JSON Schema object.
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    func call(_ args: [String: JSONValue]) async throws -> String
    /// Human-in-the-loop: return a request when this input should be shown to a
    /// person before running (default `nil` — see `Approval.swift`).
    func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest?
}

public struct ToolError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Strands `ToolSpec`: what the model is told about a tool.
public struct ToolSpec: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
    /// OpenAI-style function spec — the shape HF chat templates understand.
    public var openAIFunction: JSONValue {
        .object(["type": "function",
                 "function": .object(["name": .string(name), "description": .string(description), "parameters": inputSchema])])
    }
}

extension Tool {
    public var toolSpec: ToolSpec { ToolSpec(name: name, description: description, inputSchema: parameters) }
    /// OpenAI-style function spec (0.1 name, kept).
    public var spec: JSONValue { toolSpec.openAIFunction }
}

extension Array where Element == ToolSpec {
    /// `[[String: Any]]` for `applyChatTemplate(messages:tools:)`.
    public var templateDictionaries: [[String: any Sendable]] {
        map { ($0.openAIFunction.anyValue as? [String: any Sendable]) ?? [:] }
    }
}

/// Tool specs as `[[String: Any]]` for `applyChatTemplate(messages:tools:)` (0.1 helper).
public func toolSpecs(_ tools: [any Tool]) -> [[String: any Sendable]] {
    tools.map(\.toolSpec).templateDictionaries
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
