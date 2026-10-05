# Messages & events

## Message

```swift
public enum Message: Sendable, Hashable, Codable {
    case system(String)
    case user(String)
    case assistant(text: String, toolCalls: [ToolCall])
    case tool(result: String, callId: String, name: String)

    public var role: String            // "system" | "user" | "assistant" | "tool"
    public var text: String
    public var toolCalls: [ToolCall]   // non-empty only for .assistant
    public var templateDictionary: [String: any Sendable]   // OpenAI-style dict for chat templates
}

public struct ToolCall: Sendable, Hashable, Codable, Identifiable {
    public var id: String              // "call_xxxxxxxx" (ToolCall.makeId())
    public var name: String
    public var arguments: [String: JSONValue]
}
```

An `enum` rather than a struct-with-content-blocks: on-device models never return mixed text+tool blocks in one turn — a
turn is either text, text plus parsed calls, or a tool result — so the four cases cover everything the chat templates
need. `templateDictionary` renders exactly what swift-transformers' `applyChatTemplate` expects (`tool_calls` on the
assistant turn, `role: tool` + `tool_call_id` on results).

## ModelEvent — what a `Model` emits

```swift
public enum ModelEvent: Sendable {
    case text(String)        // token delta
    case toolCall(ToolCall)  // only if the runtime parsed the call itself (mlx-swift-lm native parsers)
    case metrics(Metrics)    // TTFT / tok/s snapshots; the last one has finished = true
}
```

Runtimes that only produce text emit `.text`; the agent lifts `<tool_call>…</tool_call>` (Hermes/Qwen),
`<|python_tag|>` / bare JSON (Llama 3) or generic JSON into `ToolCall`s after the turn with `ToolCallParser`.

## AgentEvent — what `Agent.stream` yields

| Event | When |
|---|---|
| `.iterationStarted(Int)` | a new pass of the loop (1-based) |
| `.text(String)` | streamed assistant text |
| `.metrics(Metrics)` | TTFT, tok/s, context used/max — updated while generating |
| `.assistantMessage(Message)` | the turn is complete and parsed (text + calls) |
| `.toolStarted(ToolCall)` | a tool is about to run |
| `.toolFinished(ToolResult)` | it returned — `isError`, `durationMs`, `content` |
| `.warning(String)` | loop detector fired (informational; never stops the loop) |
| `.finished(iterations: Int, reason: FinishReason)` | `.answered` · `.budget` · `.cancelled` |

```swift
public struct Metrics: Sendable, Hashable {
    public var promptTokens: Int
    public var generatedTokens: Int
    public var ttftMs: Double
    public var tokensPerSecond: Double
    public var contextUsed: Int
    public var contextMax: Int
    public var finished: Bool
    public var stopReason: String      // runtime's own word: "end_turn", "max_tokens", …
    public var estimated: Bool         // true when token counts come from a heuristic, not the tokenizer
}
```

## Persisting a conversation

`Message` is `Codable`; `agent.messages` is a plain array you can save and restore (`agent.messages = saved` inside the
actor, or build a new `Agent` and assign). The app keeps the current conversation in Application Support.

## Transcript — events → UI state

`Transcript` (in `Loopl`, no SwiftUI) folds `AgentEvent`s into a list a view can render:

```swift
public struct Transcript: Sendable, Hashable {
    public var items: [TranscriptItem]      // kind: .user · .assistant · .toolCall(ToolCall, result: ToolResult?) · .warning · .note
    public var metrics: Metrics
    public var iteration: Int
    public var isRunning: Bool
    public mutating func user(_ text: String)
    public mutating func apply(_ event: AgentEvent) -> Bool   // true when the item list changed; streaming text merges into the open assistant item
    public mutating func note(_ text: String)
    public mutating func clear()
}
```

`LooplUI.AgentTranscriptView(transcript)` renders it — `UserBubble`, `StreamingTextView`, `ToolCallCard` (collapsed pill →
expandable arguments/result, ✓/✗), warnings as amber pills — and `TokenMeter(metrics)` draws TTFT / tok/s / context used.
