import Foundation

/// A tool the agent may call. `parameters` is a JSON Schema object.
public protocol AgentTool: Sendable {
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

extension AgentTool {
    /// OpenAI-style function spec — the shape HF chat templates understand.
    public var spec: JSONValue {
        .object(["type": "function",
                 "function": .object(["name": .string(name), "description": .string(description), "parameters": parameters])])
    }
}

/// Tool specs as `[[String: Any]]` for `applyChatTemplate(messages:tools:)`.
public func toolSpecs(_ tools: [any AgentTool]) -> [[String: any Sendable]] {
    tools.map { ($0.spec.anyValue as? [String: any Sendable]) ?? [:] }
}
