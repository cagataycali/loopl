import Foundation

/// A tool the agent may call (`AgentTool`). `parameters` is a JSON Schema object.
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    func call(_ args: [String: JSONValue]) async throws -> String
    /// Human-in-the-loop: return a request when this input should be shown to a
    /// person before running (default `nil` — see `Approval.swift`).
    func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest?
    /// `true` when the tool decodes and complains about its own input (e.g.
    /// `StructuredOutputTool`, whose error result IS the repair signal). The
    /// agent's schema pre-check (`ToolValidation`) then leaves the input alone.
    /// Default `false`.
    var validatesOwnInput: Bool { get }
    /// A runtime this tool merely wraps. When the agent's model *is* that runtime
    /// the tool is not offered (and not run): asking Apple Intelligence to call an
    /// `apple_intelligence` tool makes a 3B model summarise "hey" in a loop.
    /// Default `nil` — offered to every model.
    var redundantWithRuntime: RuntimeKind? { get }
}

extension Tool {
    public var redundantWithRuntime: RuntimeKind? { nil }
    /// Whether this tool is offered to a model of `kind` (see `redundantWithRuntime`).
    public func isOffered(to kind: RuntimeKind) -> Bool { redundantWithRuntime != kind }
}

public struct ToolError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// `ToolSpec`: what the model is told about a tool.
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
    public var validatesOwnInput: Bool { false }
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

// MARK: - Tools that produce or consume pictures (Phase 4, APPLE-TOOLS)

/// What a tool hands back: the text the model reads, plus pictures the
/// transcript renders (`ToolResult.images`). `call(_:)` returning a String is
/// `ToolOutput(text:)` — the image-aware entry points below default to it.
public struct ToolOutput: Sendable, Hashable {
    public var text: String
    public var images: [ImageBlock]
    public init(text: String, images: [ImageBlock] = []) { self.text = text; self.images = images }
}

extension Tool {
    /// Image-producing tools override this (and make `call(_:)` return the prose only).
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        ToolOutput(text: try await call(args))
    }
    /// Image-consuming tools override this. `images` are the pictures attached to
    /// the latest user message (most recent last); the default ignores them.
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput {
        try await callOutput(args)
    }
}
