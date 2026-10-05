# Messages & events

## Message

```swift
public struct Message: Sendable, Codable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public let id: UUID
    public let role: Role
    public var content: [ContentBlock]

    public static func system(_ text: String) -> Message
    public static func user(_ text: String) -> Message
    public static func assistant(_ text: String, toolUses: [ToolUse] = []) -> Message
    public static func toolResult(_ result: ToolResult) -> Message

    public var text: String            // all .text blocks joined
    public var toolUses: [ToolUse]     // all .toolUse blocks
}

public enum ContentBlock: Sendable, Codable, Equatable {
    case text(String)
    case toolUse(ToolUse)              // id, name, input (JSONValue)
    case toolResult(ToolResult)        // toolUseId, content, status (.success | .error)
}
```

The shape is deliberately Strands' `Message`/`ContentBlock`, which is also what every chat template we
render understands (OpenAI-style `tool_calls` + `tool` role messages).

## ModelEvent — what a `Model` emits

```swift
public enum ModelEvent: Sendable {
    case textDelta(String)
    case toolUse(ToolUse)              // native tool call (Apple FM, mlx-swift-lm parsers)
    case usage(inputTokens: Int, outputTokens: Int)
    case metrics(ttftMs: Double, tokensPerSecond: Double)
    case stop(StopToken)               // .endOfTurn | .maxTokens | .contextFull | .stopSequence(String)
}
```

Runtimes that only produce text (plain GGUF, Gemma) emit `textDelta` and let the core's
`ToolCallParser` lift `<tool_call>…</tool_call>` / `<|python_tag|>` / bare-JSON into `ToolUse`s after
the turn.

## AgentEvent — what `Agent.stream` yields

| Event | When |
|---|---|
| `.iteration(Int)` | a new pass of the loop starts (1-based) |
| `.textDelta(String)` | streamed assistant text |
| `.toolUseStart(ToolUse)` | the model decided to call a tool (after the turn is parsed, before it runs) |
| `.toolUseDelta(id: String, argsFragment: String)` | partial arguments, native runtimes only |
| `.toolResult(ToolResult)` | the tool returned (success or error) |
| `.warning(Warning)` | loop detector fired, or budget at 80 % |
| `.turnEnd(Metrics)` | a model turn finished — tokens, TTFT, tok/s, context used/max |
| `.done(StopReason)` | the loop ended |

```swift
public struct Metrics: Sendable, Equatable {
    public var inputTokens: Int, outputTokens: Int
    public var ttftMs: Double
    public var tokensPerSecond: Double
    public var contextUsed: Int, contextMax: Int
    public var wallMs: Double
    public var iterations: Int
}
```

`LooplUI.TokenMeter` renders a `Metrics` value; `AgentTranscriptView` consumes the whole event stream.

## Persisting a conversation

`Message` is `Codable`. The app writes the current conversation as JSON to Application Support; you
can do the same and pass it back with `agent.stream(messages:)` or `Agent(..., history: saved)`.
