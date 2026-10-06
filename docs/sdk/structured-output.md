---
title: "Structured output"
description: "Ask the agent for a Swift value instead of prose. The schema comes from Decodable; malformed answers are repaired."
---

# Structured output

Ask for a value, get a value.

```swift
// snippet: compile
import Loopl

struct Weather: Codable, Sendable {
    let city: String
    let celsius: Int
    let summary: String?
}

func report(_ agent: Agent) async throws -> Weather {
    try await agent.structured(As: Weather.self, prompt: "Weather in Istanbul right now")
}
```

The JSON schema is **derived from `Decodable`** and offered to the model as one tool, `structured_output`. Its arguments are the answer; they decode straight into `Weather` and the run ends there.

If the model answers in prose, a second pass offers **only** that tool — on-device models have no `tool_choice`, so this is how loopl insists. Still prose: `StructuredOutputError.notCalled`, never a guess. Malformed arguments go back as an error naming the field, so the model can repair them (`maxRepairs`, default 1).

## Options

```swift
// snippet: compile
import Loopl

struct Reading: Codable, Sendable { let city: String; let celsius: Int }

func tuned(_ model: any Model) async throws {
    let agent = Agent(model: model, tools: [CalculatorTool()])
    var options = StructuredOutputOptions()
    options.describe = ["city": "City name, as the user wrote it", "celsius": "Temperature in °C"]
    options.withTools = true          // the first pass may still use other tools
    options.maxRepairs = 2
    options.discardHistory = true     // leave the conversation untouched
    let run = try await agent.structuredRun(As: Reading.self, prompt: "weather in Izmir", options: options)
    print(run.value.city, run.forced, run.repairs, run.result.metrics.cycleCount)
}
```

## Schemas

| Swift | JSON schema |
|---|---|
| `String` · `Int` · `Double` · `Bool` | `string` · `integer` · `number` · `boolean` |
| `T?` | not `required` |
| nested struct · `[T]` | `object` · `array` |
| `Date` · `URL` · `UUID` · `Data` | `string` with a format |
| `enum E: String, Codable, SchemaEnum` | `string` + `enum` |

A type that validates in `init(from:)`, or a recursive one, can't be derived — `SchemaDerivationError` asks you to declare it:

```swift
// snippet: compile
import Loopl

struct Rating: Codable, Sendable, JSONSchemaProviding {
    let stars: Int
    static var jsonSchema: JSONValue {
        ToolSchema.object(["stars": ToolSchema.number("1 to 5")], required: ["stars"])
    }
}
```

Works on MLX and llama.cpp; best effort on Apple's model. Small models do better with few, well-described fields.
