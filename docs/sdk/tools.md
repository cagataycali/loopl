---
title: Tools
description: Give the agent a Tool — a name, a description, a JSON schema and an async call. Six ship built in; the model decides when to use them.
---

# Tools

A `Tool` is a name, a description, a JSON schema and one async function. The model sees the schema; loopl parses the call, runs it and feeds the result back.

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

Return a string; throw `ToolError` for a failure the model should read. The agent never crashes on a tool — the error text becomes the tool result.

## One-liners

```swift
// snippet: compile
import Loopl
import Foundation

let battery = ClosureTool(name: "battery_level",
                          description: "The device battery level in percent.") { _ in
    "\(Int.random(in: 20...100)) %"           // UIDevice.current.batteryLevel in the app
}
```

## Schemas

`ToolSchema` builds the common shapes; `JSONValue` is literal-convertible for anything else.

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

## Built in

| Tool | does |
|---|---|
| `CurrentTimeTool` | time in a zone or city |
| `CalculatorTool` | arithmetic (`Calculator`, no `eval`) |
| `RememberTool` / `RecallTool` | on-device notes (`NotesStore`) |
| `HttpGetTool` | GET a URL — blocked when `NetworkPolicy` is offline |

## How calls reach your code

- Tool specs go through the model's chat template (`ToolSpec`); small models emit `<tool_call>` JSON, which `ToolCallParser` reads per `ToolFamily` (Qwen, Llama, Gemma, …).
- `ToolCallStreamGate` holds back the raw JSON so the UI never flashes it.
- All calls in one turn run concurrently (`ConcurrentToolExecutor`); pass `SequentialToolExecutor` to serialise.
- Veto or rewrite a call from a [hook](hooks.md) (`BeforeToolCallEvent.cancelTool`).

Every event a call emits — `.toolUseStream`, `.toolStarted(ToolUse)`, `.toolResult(ToolResult)` — carries the same `toolUseId`, so a UI row can follow one call from first byte to result.
