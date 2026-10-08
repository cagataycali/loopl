---
title: "Tools"
description: "A tool is a name, a description, a JSON schema and an async function. loopl ships the iPhone's own abilities as tools."
---

# Tools

A `Tool` is a name, a description, a JSON schema and one async function. The model reads the schema; loopl parses its call, runs your function and hands the result back.

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
        return "\(city): 21 °C, clear, \(days)-day outlook stable"
    }
}
```

Return a string. Throw `ToolError` for a failure the model should read — a tool never crashes the agent; the error becomes the result.

For one-liners there is `ClosureTool`:

```swift
// snippet: compile
import Loopl
import Foundation

let battery = ClosureTool(name: "battery_level",
                          description: "The device battery level in percent.") { _ in
    "\(Int.random(in: 20...100)) %"
}
```

`ToolSchema` builds the common shapes; `JSONValue` is a literal for anything else:

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

## The iPhone, as tools

`LooplAppleTools` wraps what the phone already does — no account, no download. Each reports `availability()`, so you only offer what this device can run.

| Tool | |
|---|---|
| `generate_image` | a picture from a prompt (Image Playground) |
| `generate_voice` | speech with on-device voices, Personal Voice included |
| `transcribe` | speech to text, offline — the app's composer records a take for it |
| `translate` | Apple's offline translation |
| `describe_image` | Vision on an attached photo |
| `flashlight` | torch on, off, toggle, brightness |
| `vibrate` | haptic patterns |
| `open_app` | another app via deep link, with context — asks first unless the scheme is allow-listed |

```swift
// snippet: compile(wrap)
import LooplAppleTools
let tools: [any Tool] = AppleTools.available   // what this device can do right now
// shortcuts://run-shortcut?name=Log%20Water&input=text&text=500%20ml
_ = try OpenAppTool.parse(["url": "shortcuts://run-shortcut?name=Log%20Water", "params": ["input": "text", "text": "500 ml"]])
```

A recording reaches `transcribe` as a line in the user's message, not as hidden audio: `AudioAttachmentMarker` (LooplUI) writes `[audio attached: <path> (<s> s) — call transcribe with this path to hear it]` and `AudioAttachmentMarker.split(_:)` reads it back for the chip. The model chooses to listen.

`open_app` merges `params` into the link's query string, so the next app starts with context; `fallback_url` opens when the app is missing.

## A result can carry a control

A tool's result is text the model reads — plus, optionally, one small **typed control** the transcript draws live: a "Turn off" switch under a flashlight result, a mini player under `music`, a pin on a map under `location`. The *tool* attaches it; the model never emits or sees it (zero tokens, nothing a small model can get wrong).

```swift
// snippet: compile
import Loopl

struct Lamp: Tool {
    let name = "lamp"
    let description = "Turn the desk lamp on or off."
    let parameters = ToolSchema.object(["state": ToolSchema.string("on or off")], required: ["state"])
    func call(_ args: [String: JSONValue]) async throws -> String { try await callOutput(args).text }
    func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        let on = args["state"]?.stringValue == "on"
        return ToolOutput(text: on ? "lamp: on" : "lamp: off",
                          control: .toggle(label: on ? "Turn off" : "Turn on", on: on,
                                           action: ControlAction(tool: "lamp", args: ["state": .string(on ? "off" : "on")])))
    }
    func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}
```

`ToolControl` is one of: `toggle{label, on, action}` · `button{label, action}` (do it again) · `player{title, subtitle?, playing, volume?, tool}` (previous / play-pause / next / volume, every button an action on `tool`) · `mapPin{lat, lon, label?}` · `timer{until, label?}` · `link{label, url}` (open another app). It travels on `ToolResult.control`, is `Codable` as a flat `{"type": …}` object (so History files and datasets can read it; an unknown future type decodes as none), and stays out of `promptContent`.

A tap runs **the same tool with the control's `args` through the agent's normal tool path** — `Agent.invokeTool(_:)`: hooks and the approval policy apply, a registry may mount the tool, `.toolStarted` / `.toolResult` stream as usual — with **no model call**. The fresh result replaces the card's. The model's history gets one tool-use + tool-result pair whose result starts with `[the user tapped this in the app]`, so the next turn knows the lamp is off and who did it. `Transcript.applyControlResult(for:_:)` updates the tapped row in place (`controlTaps` counts).

The on-device tools that ship controls: `flashlight` (Turn off / Turn on), `vibrate` (Vibrate again), `music` (mini player), `location` (map pin, at the same rounding the model got), `calendar_create` / `reminders_create` (Open in Calendar / Reminders).

## Built in

| Tool | |
|---|---|
| `CurrentTimeTool` | time in any zone |
| `CalculatorTool` | exact arithmetic, no `eval` |
| `RememberTool` · `RecallTool` | notes on the device (`NotesStore`) |
| `HttpTool` | any HTTPS request; asks before it runs ([Human in the loop](hitl.md)); refused in offline mode |

## The agent manages its own tools

A `ToolRegistry` holds every tool the agent *knows* — mounted or not, runnable here or not (with the reason) — and the subset the model is offered. Give the agent one and `tools` becomes a mirror of `registry.mounted`, read **when each model request is built**, not once per run:

```swift
// snippet: compile(wrap)
import Loopl
let registry = ToolRegistry(catalog: [CurrentTimeTool(), CalculatorTool(), HttpTool()],
                            mounted: ["current_time"], selfManaging: true)   // + manage_tools, pinned
// let agent = Agent(model: model, systemPrompt: "…", registry: registry)
await registry.mount(["http"])                 // effective for the very next model call — same turn
let names = await registry.mountedNames        // ["current_time", "http", "manage_tools"]
```

`selfManaging: true` registers `manage_tools` (`ManageToolsTool`) bound to that registry: `list` shows the model every known tool and why one cannot run here, `mount` / `unmount` change the set, `describe` prints one tool's parameters. Because the agent re-reads the registry before every request and before running a message's calls, a tool the model mounts in cycle *n* is both **offered** and **runnable** in cycle *n + 1* of the same turn — the proof is `ToolRegistryTests.testMountMidTurnIsOfferedOnTheNextModelCall` (three requests, one user message, request 2 carries `http`). `AgentEvent.toolsChanged(mounted:)` fires whenever the offered list changes, so a UI can show it.

The model never loads code: there is no `create` action. A host adds tools at runtime with `register(_:source:…)` (mounted by default — the point of registering mid-task is to use it); `setMounted(_:)` replaces the set wholesale, the way a host applies its Settings; pinned tools stay, unavailable ones stay out.

## How a call reaches your code

- Small models write calls in many dialects. `ToolCallParser` reads them all: `{"name", "arguments"}`, flat calls, `<tool_call>` JSON, fenced JSON, Llama's `<|python_tag|>`, the Qwen XML `<function=…>` form.
- `ToolValidation` repairs what it safely can — quoted numbers, `uri` for `url`, a bare value into the one missing field — and refuses the rest with an example of the right shape, so the model can correct itself.
- `ToolCallStreamGate` keeps raw call JSON out of the visible text.
- A failure is a result, not a retry rule. A thrown `ToolError`, a refused argument, an HTTP 4xx/5xx or an unknown tool name (`Unknown tool: X. Available tools: …`) comes back as `ToolResult.error`; the model reads it as `ERROR: <message>` (`ToolResult.promptContent`) and decides — call again with better arguments, or answer. There is no repeat heuristic in the loop.
- On MLX, tool specs reach the chat template in the key order the models were trained on (`type`, `function`, `name`, `description`, `parameters`), not alphabetically.
- All calls in a turn run concurrently; pass `SequentialToolExecutor` to serialise.
- Every event of one call carries the same `toolUseId`, so a UI row can follow it from first byte to result.
