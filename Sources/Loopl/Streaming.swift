import Foundation

// `types/streaming.py` + `event_loop/streaming.py` + `_recover_message_on_max_tokens_reached.py`.

/// `StopReason`. (Checkpoint/interrupt/guardrail/limit_* variants have no
/// edge equivalent and are intentionally absent — loopl has no caps.)
public enum StopReason: String, Sendable, Codable, Hashable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case contentFiltered = "content_filtered"
    case cancelled
    /// A hook or a tool raised an interrupt and `InterruptMode.stop` ended the loop.
    /// `AgentResult.interrupts` carries them; answer and call `agent.resume(_:)`.
    case interrupt
}

/// `Usage`.
public struct Usage: Sendable, Hashable, Codable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var totalTokens: Int = 0
    public init(inputTokens: Int = 0, outputTokens: Int = 0, totalTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.totalTokens = totalTokens
    }
    public static func += (a: inout Usage, b: Usage) {
        a.inputTokens += b.inputTokens; a.outputTokens += b.outputTokens; a.totalTokens += b.totalTokens
    }
}

/// Live numbers for a debug sheet — every one measured by the runtime, none
/// invented (`estimated` flags runtimes without a tokenizer, e.g. Apple FM).
public struct Metrics: Sendable, Hashable, Codable {
    public var promptTokens: Int = 0
    public var generatedTokens: Int = 0
    /// Milliseconds from `stream()` call to the first visible token.
    public var ttftMs: Double = 0
    /// Decode speed (generated tokens / generation seconds), excluding prefill.
    public var tokensPerSecond: Double = 0
    public var contextUsed: Int = 0
    public var contextMax: Int = 0
    public var finished = false
    public var stopReason: String = ""
    public var estimated = false
    public init() {}
    public var usage: Usage { Usage(inputTokens: promptTokens, outputTokens: generatedTokens, totalTokens: promptTokens + generatedTokens) }
}

/// `ContentBlockStart` — the toolUse variant carries id + name.
public enum ContentBlockStart: Sendable, Hashable {
    case text
    case toolUse(toolUseId: String, name: String)
    case reasoning
}

/// `ContentBlockDelta`.
public enum ContentBlockDelta: Sendable, Hashable {
    case text(String)
    /// A partial JSON string of the tool input.
    case toolUse(input: String)
    case reasoning(String)
    /// The text block's content so far is now exactly this (not a delta). Runtimes
    /// that only see cumulative snapshots (Apple Foundation Models) use it when a
    /// snapshot is not an extension of the previous one, and when a finished answer
    /// turns out to be a JSON wrapper that is unwrapped into prose.
    case textReplace(String)
}

/// `StreamEvent` — what a `Model` emits. Exactly the Bedrock-shaped
/// union `process_stream` consumes.
public enum StreamEvent: Sendable, Hashable {
    case messageStart(role: Role)
    case contentBlockStart(ContentBlockStart)
    case contentBlockDelta(ContentBlockDelta)
    case contentBlockStop
    case messageStop(StopReason)
    case metadata(Metrics)
}

/// `event_loop.streaming.process_stream`: fold `StreamEvent`s into
/// the assistant `Message`, yielding typed events for the UI as it goes.
public struct StreamAssembler: Sendable {
    /// What the assembler emits while it folds stream events into a message.
    public enum Event: Sendable {
        case chunk(StreamEvent)                 // ModelStreamChunkEvent
        case text(String)                       // TextStreamEvent
        case textReplace(String)                // loopl: the streamed text so far is now exactly this
        case reasoning(String)                  // ReasoningTextStreamEvent
        case toolUse(name: String, toolUseId: String, partialInput: String)   // ToolUseStreamEvent
    }
    /// The assembled message and why the model stopped.
    public struct Stop: Sendable {
        public var stopReason: StopReason
        public var message: Message
        public var metrics: Metrics
    }

    public private(set) var message = Message(role: .assistant, content: [])
    private var text = ""
    private var reasoningText = ""
    private var currentToolUse: (id: String, name: String, input: String)?
    private var stopReason: StopReason = .endTurn
    private var sawMessageStop = false
    public private(set) var metrics = Metrics()

    public init() {}

    /// `handle_message_start` … `handle_message_stop` in one switch.
    public mutating func feed(_ event: StreamEvent) -> [Event] {
        var out: [Event] = [.chunk(event)]
        switch event {
        case .messageStart(let role):
            message.role = role
        case .contentBlockStart(let start):
            if case .toolUse(let id, let name) = start { currentToolUse = (id, name, "") } else { currentToolUse = nil }
        case .contentBlockDelta(let delta):
            switch delta {
            case .text(let t): text += t; out.append(.text(t))
            case .textReplace(let s): text = s; out.append(.textReplace(s))
            case .reasoning(let r): reasoningText += r; out.append(.reasoning(r))
            case .toolUse(let partial):
                if currentToolUse == nil { currentToolUse = ("", "", "") }
                currentToolUse!.input += partial
                out.append(.toolUse(name: currentToolUse!.name, toolUseId: currentToolUse!.id, partialInput: currentToolUse!.input))
            }
        case .contentBlockStop:
            contentBlockStop()
        case .messageStop(let reason):
            sawMessageStop = true
            // Some models return end_turn even with tool calls present — override to tool_use.
            stopReason = (reason == .endTurn && message.hasToolUse) ? .toolUse : reason
        case .metadata(let m):
            metrics = m
        }
        return out
    }

    /// `handle_content_block_stop`.
    private mutating func contentBlockStop() {
        if let cur = currentToolUse {
            var input: [String: JSONValue] = [:]
            let raw = cur.input.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { input = JSONValue.parse(raw)?.objectValue ?? [:] }   // unparsable → {}
            if cur.id.isEmpty || cur.name.isEmpty {
                currentToolUse = nil                       // incomplete block → skipped
                return
            }
            message.content.append(.toolUse(ToolUse(toolUseId: cur.id, name: cur.name, input: input)))
            currentToolUse = nil
        } else if !text.isEmpty {
            message.content.append(.text(text)); text = ""
        } else if !reasoningText.isEmpty {
            message.content.append(.reasoning(reasoningText)); reasoningText = ""
        }
    }

    /// End of the stream. An unterminated block is closed; a stream that never
    /// sent `messageStop` ends as `endTurn` (or `toolUse` when calls exist).
    public mutating func finish() -> Stop {
        if currentToolUse != nil || !text.isEmpty || !reasoningText.isEmpty { contentBlockStop() }
        if !sawMessageStop, message.hasToolUse { stopReason = .toolUse }
        var m = metrics; m.finished = true; if m.stopReason.isEmpty { m.stopReason = stopReason.rawValue }; metrics = m
        return Stop(stopReason: stopReason, message: message, metrics: m)
    }
}

/// `recover_message_on_max_tokens_reached`: a message cut off by the
/// token limit may carry a half-written tool use — replace every toolUse block
/// with a text block saying so, so the model sees what happened and no tool runs
/// on garbage input.
public func recoverMessageOnMaxTokensReached(_ message: Message) -> Message {
    var out = message
    out.content = message.content.map { block in
        guard let use = block.toolUse else { return block }
        let name = use.name.isEmpty ? "<unknown>" : use.name
        return .text("The selected tool \(name)'s tool use was incomplete due to maximum token limits being reached.")
    }
    return out
}
