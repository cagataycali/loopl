---
description: Tools in loopl — the Tool protocol, ToolSchema, ClosureTool, how tool calls are parsed from each model family, concurrent execution and error handling.
---

# Tools & JSON schema

A tool is a Swift value the model can call. Define it once; loopl renders its schema into whatever dialect the loaded
model speaks (Qwen/Hermes `<tool_call>`, Llama 3 `<|python_tag|>`, Gemma/SmolLM fenced JSON, Apple Foundation Models'
instructions), parses the call back, runs it, and returns the result to the model as a `toolResult` block.

```swift
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }                              // JSON Schema for the arguments
    func call(_ args: [String: JSONValue]) async throws -> String  // what the model reads back
}
```

That is Strands' `@tool` surface — `name`, `description`, an input schema, a body — without decorators: Swift has no
runtime introspection of parameter names, so you state the schema. `ToolSchema` keeps that short.

## A struct

```swift
// snippet: compile
import Loopl
import Foundation

struct Weather: Tool {
    let name = "weather"
    let description = "Current conditions for a city. Celsius."
    let parameters = ToolSchema.object(
        ["city": ToolSchema.string("City name, e.g. Istanbul"),
         "days": ToolSchema.number("Forecast length in days, 1–7")],
        required: ["city"])

    func call(_ args: [String: JSONValue]) async throws -> String {
        guard let city = args["city"]?.stringValue else { throw ToolError("city is required") }
        let days = Int(args["days"]?.doubleValue ?? 1)
        return "\(city): 21 °C, clear, \(days)-day outlook stable"      // call your own source here
    }
}
```

`ToolSchema.object(_:required:)`, `.string`, `.number`, `.boolean` build the JSON Schema; for anything richer (enums,
arrays, nested objects) write the `JSONValue` literal directly — it *is* JSON:

```swift
// snippet: compile
import Loopl

let schema: JSONValue = [
    "type": "object",
    "properties": [
        "unit": ["type": "string", "enum": ["c", "f"]],
        "cities": ["type": "array", "items": ["type": "string"]]
    ],
    "required": ["cities"]
]
```

## A closure

For one-offs, `ClosureTool` wraps a closure:

```swift
// snippet: compile
import Loopl
import Foundation

let battery = ClosureTool(name: "battery_level",
                          description: "The device battery level in percent.") { _ in
    "\(Int.random(in: 20...100)) %"           // UIDevice.current.batteryLevel in the app
}
```

## Built-in tools

| Tool               | `name`         | What it does                                                                    |
|--------------------|----------------|---------------------------------------------------------------------------------|
| `CurrentTimeTool`  | `current_time` | Date & time, optional IANA `timezone`                                           |
| `CalculatorTool`   | `calculator`   | Exact arithmetic (`+ - * / % ^`, `sqrt`, `abs`, `round`…) via loopl's `Calculator` |
| `RememberTool`     | `remember`     | Store a short note under a key (UserDefaults-backed)                            |
| `RecallTool`       | `recall`       | Read one note or list all                                                       |
| `HttpGetTool`      | `http_get`     | HTTPS GET, first 4000 chars; refuses while offline                              |

All are plain structs in `Sources/Loopl/BuiltinTools.swift` — copy one when you start your own.

## How a call gets parsed

Small models do not have a native tool-calling API. loopl's `PromptBuilder` puts the tool specs into the chat template
(or the system prompt for runtimes without a template) and `ToolCallParser` recognises the model's reply by **family**:

| `ToolFamily` | Models                                   | Wire format                                                     |
|--------------|------------------------------------------|-----------------------------------------------------------------|
| `.hermes`    | Qwen 2.5 / 3, Hermes, SmolLM3, Phi-4-mini | `<tool_call>{"name": …, "arguments": {…}}</tool_call>`           |
| `.llama3`    | Llama 3.1 / 3.2                           | `<|python_tag|>{…}` or a bare `{"name": …, "parameters": {…}}`   |
| `.generic`   | Gemma, SmolLM2, Apple Foundation Models  | fenced ```json … ``` or a bare JSON object with `name` + `arguments` |

The family comes from the model's catalog entry. Partial calls are held back by `ToolCallStreamGate` so the UI never
flashes half a `<tool_call>` tag, and a call truncated by `maxTokens` is repaired when the JSON is unambiguous. Parsed calls
become `StreamEvent.contentBlockStart(.toolUse)` + `contentBlockDelta(.toolUse(input:))`, so by the time the loop sees
them every model looks like a native tool-calling model.

## Execution: concurrent by default

When an assistant message carries several tool uses, the `ToolExecutor` runs them. `ConcurrentToolExecutor` (default)
runs all of them in a `TaskGroup` and returns the results **in the order the model asked**; `SequentialToolExecutor`
runs one at a time for tools that share a resource. Either way:

- a tool that **throws** becomes `ToolResult(status: .error, content: <error text>)` — the model reads it and usually
  retries with better arguments; the loop never crashes on a tool;
- a tool the model names that **does not exist** gets an error result naming the available tools;
- `BeforeToolCallEvent` can swap or deny the tool, `AfterToolCallEvent` can rewrite the result ([Hooks](hooks.md));
- each result carries `durationMs`, surfaced on the UI tool row and in `EventLoopMetrics.toolCallCount`.

## Tips for small models

- **Short descriptions, few parameters.** A 1.7B model follows a two-field schema reliably; it loses an eight-field one.
- **Return text the model can quote.** `"21 °C, clear"` beats a JSON blob the model has to re-parse.
- **Name the unit in the description** ("Celsius", "ISO-8601") instead of relying on an enum.
- **Fail loudly in `call`.** `throw ToolError("city is required")` teaches the model more than returning an empty string.

!!! strands "Strands → loopl"
    `@tool def weather(city: str) -> str` → `struct Weather: Tool` · `ToolSpec` → `ToolSpec` (via `tool.toolSpec`) ·
    `ToolUse` → `ToolUse` · `ToolResult(status="error")` → `ToolResult(status: .error)` · `ConcurrentToolExecutor` → `ConcurrentToolExecutor`.
