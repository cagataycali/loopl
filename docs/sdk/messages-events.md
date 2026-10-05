---
description: loopl's data model — Message, ContentBlock, ToolUse, ToolResult — and the two event vocabularies, StreamEvent (model → loop) and AgentEvent (loop → you).
---

# Messages & stream events

Two layers, both borrowed from Strands so the mental model transfers:

1. **Messages** are the conversation — what is sent to the model and kept in `agent.messages`.
2. **Events** are what flows while a turn runs: `StreamEvent`s from the model into the loop, `AgentEvent`s from the loop to you.

## Message

```swift
public struct Message: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var role: Role                  // .system · .user · .assistant · .tool
    public var content: [ContentBlock]

    public static func user(_ text: String) -> Message
    public static func assistant(_ text: String) -> Message
    public static func assistant(text: String, toolUses: [ToolUse]) -> Message
    public static func toolResults(_ results: [ToolResult]) -> Message     // role .user, like Strands

    public var text: String                // all .text blocks joined
    public var reasoning: String
    public var toolUses: [ToolUse]
}

public enum ContentBlock: Sendable, Hashable, Codable {
    case text(String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    case reasoning(String)                 // Qwen3 <think>… — kept in history, UIs may hide it
}
```

This is Strands' `Message = {role, content: [ContentBlock]}` with the same four block kinds. Tool results travel in a
`user` message, exactly as Bedrock and Strands expect, so a transcript round-trips to any Strands-shaped tool unchanged.

```swift
public struct ToolUse: Sendable, Hashable, Codable, Identifiable {
    public var toolUseId: String           // "tooluse_xxxxxxxx" — generated if the model did not supply one
    public var name: String
    public var input: [String: JSONValue]
}

public struct ToolResult: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable { case success, error }
    public var toolUseId: String
    public var name: String
    public var status: Status
    public var content: String             // what the model reads back
    public var durationMs: Double
    public static func error(_ toolUse: ToolUse, _ message: String, durationMs: Double = 0) -> ToolResult
}
```

`JSONValue` is loopl's small JSON enum (`.string/.number/.bool/.null/.array/.object`) with literal conformances, so
`["city": "Istanbul", "days": 3]` *is* a `[String: JSONValue]`.

## StreamEvent — model → loop

Every `Model` emits the same Bedrock-shaped stream Strands uses for all its providers:

```swift
public enum StreamEvent: Sendable, Hashable {
    case messageStart(role: Role)
    case contentBlockStart(ContentBlockStart)      // .text · .toolUse(toolUseId:name:) · .reasoning
    case contentBlockDelta(ContentBlockDelta)      // .text(String) · .toolUse(input: String) · .reasoning(String)
    case contentBlockStop
    case messageStop(StopReason)
    case metadata(Metrics)
}

public enum StopReason: String, Sendable, Codable {
    case endTurn, toolUse, maxTokens, stopSequence, contentFiltered, cancelled
}
```

A runtime that only produces raw tokens (llama.cpp) or snapshots (Apple Foundation Models) adapts to this vocabulary
inside its `Model`; the `ToolCallParser` turns `<tool_call>`/JSON dialects into `contentBlockStart(.toolUse)` +
`contentBlockDelta(.toolUse(input:))` so the loop never sees a dialect.

`StreamAssembler` (Strands `process_stream`) folds the stream into one assistant `Message` and a `Stop` value
(`stopReason`, `message`, `metrics`). You only meet it when you write a `Model`.

## AgentEvent — loop → you

```swift
public enum AgentEvent: Sendable {
    case initEventLoop                                  // first cycle of an invocation
    case startEventLoop(cycle: Int)                     // each model call
    case modelStreamChunk(StreamEvent)                  // the raw stream, if you want it
    case text(String)                                   // assistant text delta
    case reasoning(String)                              // thinking delta
    case toolUseStream(name: String, toolUseId: String, partialInput: String)
    case modelMessage(Message)                          // assembled assistant turn (already appended)
    case throttle(delay: TimeInterval)                  // retry backoff announced
    case toolStarted(ToolUse)                           // after BeforeToolCall hooks, before the tool runs
    case toolResult(ToolResult)
    case toolResultMessage(Message)                     // the user message carrying all results (appended)
    case metrics(Metrics)                               // ttft, tok/s, context used/max — for a debug sheet
    case forceStop(String)                              // unrecoverable error or cancellation
    case result(AgentResult)                            // ALWAYS the last event
}
```

The Strands names are in the comments of the source (`InitEventLoopEvent`, `TextStreamEvent`, `ToolResultEvent`,
`ForceStopEvent`, `AgentResultEvent`…); only `toolStarted` and `metrics` are loopl additions, because a phone UI wants a
spinner on the tool row and a tok/s number somewhere quiet.

### From events to a view model

`Transcript` is a pure reducer from `AgentEvent` to a list of `TranscriptItem`s (`user`, `assistant`, `reasoning`,
`toolUse(_, result:)`, `note`) plus `metrics`, `cycle`, `isRunning`, `lastResult`. `LooplUI.AgentTranscriptView`
renders exactly this value; your own SwiftUI can too:

```swift
// snippet: compile
import Loopl

@MainActor
func drive(_ agent: Agent, _ prompt: String, into transcript: inout Transcript) async throws {
    transcript.user(prompt)
    for try await event in agent.stream(prompt) {
        _ = transcript.apply(event)            // returns true when the visible list changed
    }
    print(transcript.items.count, transcript.lastResult?.stopReason as Any)
}
```

## Metrics

```swift
public struct Metrics: Sendable, Hashable, Codable {
    public var promptTokens, generatedTokens: Int
    public var ttftMs: Double                 // time to first token
    public var tokensPerSecond: Double
    public var contextUsed, contextMax: Int
    public var finished: Bool
    public var stopReason: String
    public var estimated: Bool                // true when the runtime cannot count tokens (Apple FM)
    public var usage: Usage                   // Strands Usage: inputTokens · outputTokens · totalTokens
}
```

`EventLoopMetrics` on the `AgentResult` accumulates `Usage` and latency across cycles (Strands `EventLoopMetrics`).
