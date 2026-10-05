# Tools & JSON schema

A tool is a `Sendable` value with a name, a one-paragraph description, a JSON-schema `parameters` object and an async
`call` that returns a string the model will read.

```swift
public protocol Tool: Sendable {
    var name: String { get }                 // [a-z0-9_]+ — what the model writes in the call
    var description: String { get }          // the model follows this more than the schema
    var parameters: JSONValue { get }        // a JSON-schema object
    func call(_ args: [String: JSONValue]) async throws -> String
}
```

## Writing one

```swift
struct Weather: Tool {
    let name = "weather"
    let description = "Current weather for a city. Only works online — say so if it fails."
    let parameters = ToolSchema.object(["city": ToolSchema.string("City name, e.g. Istanbul")], required: ["city"])

    func call(_ args: [String: JSONValue]) async throws -> String {
        guard let city = args["city"]?.stringValue else { throw ToolError("missing 'city'") }
        if NetworkPolicy.isOffline { throw ToolError("offline mode is on — network refused") }
        // … fetch …
        return "Sunny, 22 °C in \(city)"
    }
}
```

Or inline, without a type:

```swift
let dice = ClosureTool(name: "roll_dice", description: "Roll an N-sided die",
                       parameters: ToolSchema.object(["sides": ToolSchema.number("default 6")])) { args in
    String(Int.random(in: 1...(Int(args["sides"]?.doubleValue ?? 6))))
}
```

`ToolSchema` has `object(_:required:)`, `string(_)`, `number(_)`, `boolean(_)`; anything fancier is a `JSONValue` literal
(dictionary/array/string/number/bool literals all work: `["type": "array", "items": ["type": "string"]]`).

!!! tip "Keep descriptions short and literal"
    Small models follow the *description* more than the schema. One sentence of what it does, one of when to use it,
    and "only works online" for network tools so the model can explain itself in airplane mode. `CurrentTimeTool` even
    accepts a city name because models pass "Istanbul" instead of `Europe/Istanbul` — be forgiving in `call`.

## Errors become results

Throwing from `call` is fine — the agent turns it into

```swift
public struct ToolResult: Sendable, Hashable, Identifiable {
    public var callId: String
    public var name: String
    public var content: String      // the returned string, or "error: …"
    public var isError: Bool
    public var durationMs: Double
    public var message: Message     // .tool(result:callId:name:) — what gets appended
}
```

and appends it as a `tool` message, so the model can retry with different arguments or tell the user. An unknown tool
name gets `error: unknown tool 'x'. Available: a, b, c`.

## How tools reach the model

`Tool.spec` renders the OpenAI-style `{type: "function", function: {name, description, parameters}}` object.

| Family (`ToolFamily`) | Mechanism | Parsed by |
|---|---|---|
| `.hermes` — Qwen3 / Qwen2.5 / Hermes | `tools:` passed to the chat template → `<tool_call>{json}</tool_call>` | `ToolCallParser(family: .hermes)` (+ mlx-swift-lm's own parser → `ModelEvent.toolCall`) |
| `.llama3` — Llama 3.x | `<|python_tag|>{json}` or bare `{"name":…,"parameters":…}` | `ToolCallParser(family: .llama3)` |
| `.generic` — Gemma, SmolLM, Phi, Apple FM | `PromptBuilder.toolSystemPrompt` lists the specs in the system prompt; the model answers with a bare JSON object | `ToolCallParser(family: .generic)` |

The parser also repairs calls truncated by `maxTokens` (closes the braces) so a cut-off `<tool_call>` still runs.
`Tests/LooplTests/ToolCallParserTests.swift` pins every dialect on captured model output.

## Built-in tools

| Type | `name` | Notes |
|---|---|---|
| `CurrentTimeTool` | `current_time` | optional IANA `timezone`; also understands a city ("Istanbul") |
| `CalculatorTool` | `calculator` | own recursive-descent `Calculator` (`+ - * / ^ %`, parentheses) — no `NSExpression` |
| `RememberTool` / `RecallTool` | `remember` / `recall` | `NotesStore` in Application Support, never synced |
| `HttpGetTool` | `http_get` | GETs a URL, text only, capped; refuses with `offline mode is on — network refused` when `NetworkPolicy.isOffline` |
| `DeviceInfoTool` (app) | `device_info` | battery, available memory, total RAM, OS version, offline flag, thermal state — lives in the app because it needs UIKit |

Enable them in the app under **Agent → Tools**; in code just pass the ones you want.
