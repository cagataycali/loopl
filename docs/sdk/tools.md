# Tools & JSON schema

A tool is a value type with a static spec and an async `call`.

```swift
public protocol Tool: Sendable {
    static var spec: ToolSpec { get }
    func call(_ input: ToolInput) async throws -> ToolResult
}

public struct ToolSpec: Sendable, Codable, Equatable {
    public var name: String             // [a-zA-Z0-9_-]{1,64}
    public var description: String
    public var parameters: JSONSchema   // an object schema
}
```

## Writing the schema

`JSONSchema` is a tiny builder that renders to standard JSON Schema (draft 2020-12 subset — what every
chat template and Apple's `Tool` understand):

```swift
static let spec = ToolSpec(
    name: "calculator",
    description: "Evaluate an arithmetic expression. Supports + - * / ^ % and parentheses.",
    parameters: .object([
        "expression": .string(description: "e.g. (17/100)*240"),
        "precision":  .integer(description: "decimal places", minimum: 0, maximum: 12),
    ], required: ["expression"])
)
```

Available nodes: `.string`, `.integer`, `.number`, `.boolean`, `.array(of:)`, `.object(_:required:)`,
`.enum([...])`, `.anyOf([...])`, each with an optional `description`. Render with `spec.parameters.json`.

!!! tip "Keep tool descriptions short and literal"
    Small models follow the *description* more than the schema. One sentence of what it does, one of
    when to use it. Mention "only works online" explicitly for network tools so the model can explain
    itself in airplane mode.

## Input & result

```swift
public struct ToolInput: Sendable {
    public let raw: JSONValue
    public subscript(key: String) -> JSONValue? { get }
    public func string(_ key: String) throws -> String      // throws ToolError.missing / .type
    public func int(_ key: String) throws -> Int
    public func double(_ key: String) throws -> Double
    public func bool(_ key: String) throws -> Bool
    public func decode<T: Decodable>(_ type: T.Type) throws -> T
}

public struct ToolResult: Sendable, Codable, Equatable {
    public enum Status: String, Codable, Sendable { case success, error }
    public var toolUseId: String
    public var content: String
    public var status: Status
    public static func text(_ s: String) -> ToolResult
    public static func json(_ v: some Encodable) throws -> ToolResult
    public static func error(_ message: String) -> ToolResult
}
```

Throwing from `call` is fine: the agent converts the error to `ToolResult.error("error: …")`. The model
sees it as the tool's output and can retry with different arguments or tell the user.

## How tools reach the model

| Family | Mechanism | Parsed by |
|---|---|---|
| Qwen3 / Qwen2.5 / Hermes | `tools:` in the chat template → `<tool_call>{json}</tool_call>` | `ToolCallParser.hermes` |
| Llama 3.x | `<|python_tag|>{json}` or bare `{"name":…,"parameters":…}` | `ToolCallParser.llama3` |
| Gemma 3 / SmolLM | tools listed in the system prompt, bare JSON object | `ToolCallParser.plainJSON` |
| Apple Foundation Models | native `Tool` protocol, `@Generable` arguments | runtime emits `ModelEvent.toolUse` |
| mlx-swift-lm ≥ 3.x | its own parsers (Llama 3, Qwen/Hermes, Mistral, Gemma) | runtime emits `ModelEvent.toolUse`; text parser is the fallback |

Rendering is pinned by snapshot tests per family (`Tests/LooplTests/ChatTemplateTests.swift`) so a
template change in swift-transformers cannot silently break tool calling.

## Built-in tools

| Tool | Name | Notes |
|---|---|---|
| `Clock` | `current_time` | optional IANA `timezone` |
| `Calculator` | `calculator` | safe expression evaluator, no `NSExpression` |
| `DeviceInfo` | `device_info` | battery, thermal state, available memory, online/offline |
| `HTTPGet` | `http_get` | **only when online**; refuses with a clear error offline |
| `Remember` / `Recall` | `remember`, `recall` | in-app notes, stored in Application Support, never synced |

Enable them in the app under **Agent → Tools**; in code just pass the ones you want.
