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
| `HttpTool` | `http`: GET/HEAD/POST/PUT/PATCH/DELETE with headers, body, timeout; capped response; blocked when `NetworkPolicy` is offline; writes ask for approval ([HITL](hitl.md)). `HttpGetTool` (`http_get`) stays one release as a deprecated alias |

## On-device Apple tools

`LooplAppleTools` wraps what the iPhone already does — no account, no download: `generate_image` (Image Playground, iOS 18.4+), `generate_voice` (AVSpeechSynthesizer, Personal Voice), `read_text` / `describe_image` (Vision on the attached picture), `translate` and `transcribe` (iOS 26), `detect_language`, and three device tools: `flashlight` (torch `on|off|toggle`, `level` 0–1), `vibrate` (Taptic patterns `tap double success warning error heartbeat long`, `intensity`), `open_app`. Each conforms to `AppleTool` and reports `availability()`; the app only offers what the device can run (torch and haptics are device-only — the Simulator says so).

`open_app` passes context to another app through a deeplink: `params` is a JSON object merged into the query string, percent-encoded (nested values as compact JSON). It leaves loopl, so it asks via [HITL](hitl.md) unless the scheme is on the user's allowlist (`OpenAppTool.allowedSchemes`); `fallback_url` opens when the app is missing.

```swift
// snippet: compile(wrap)
import LooplAppleTools
let tools: [any Tool] = AppleTools.available   // what THIS device can do right now
// Shortcuts with context → shortcuts://run-shortcut?name=Log%20Water&input=text&text=500%20ml
_ = try OpenAppTool.parse(["url": "shortcuts://run-shortcut?name=Log%20Water", "params": ["input": "text", "text": "500 ml"]])
// Another agent app     → tinyapp://chat?from=loopl&prompt=summarise%20my%20day
_ = try OpenAppTool.parse(["url": "tinyapp://chat", "params": ["prompt": "summarise my day", "from": "loopl"]])
```

## How calls reach your code

- Tool specs go through the model's chat template (`ToolSpec`); small models emit `<tool_call>` JSON, which `ToolCallParser` reads per `ToolFamily` (Qwen, Llama, Gemma, …).
- The parser reads what small models actually write, not only the textbook shape: `{"name", "arguments"}`, flat calls (`{"name": "http", "url": "…"}`), `{"http": {…}}`, a JSON-string `arguments`, Llama's `<|python_tag|>`, fenced ```json, and Qwen3.5 / Qwen3-Coder XML (`<function=http><parameter=url>…</parameter></function>`, including its truncated and mis-closed variants).
- `ToolValidation` then repairs against the schema (quoted numbers, `URL`/`uri`/`link` → `url`, a bare value into the one missing required key) and refuses the rest with a concrete example — `missing required parameter 'url'. Call it with arguments like {"url": "https://example.com"}` — so the model fixes its own call on the next cycle. Rejected calls are logged at debug level (`technology.tiny.loopl` / `ToolValidation`).
- `ToolCallStreamGate` holds back the raw JSON so the UI never flashes it.
- All calls in one turn run concurrently (`ConcurrentToolExecutor`); pass `SequentialToolExecutor` to serialise.
- Veto or rewrite a call from a [hook](hooks.md) (`BeforeToolCallEvent.cancelTool`).

Every event a call emits — `.toolUseStream`, `.toolStarted(ToolUse)`, `.toolResult(ToolResult)` — carries the same `toolUseId`, so a UI row can follow one call from first byte to result.
