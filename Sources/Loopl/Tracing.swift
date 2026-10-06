import Foundation

// Tracing — Strands' `telemetry/tracer.py` without OpenTelemetry. The spans an
// agent produces are the interesting part (invoke_agent → chat → execute_tool),
// and they can be built entirely out of the hooks that already exist, so loopl
// has no new dependency: `Tracer` is a `HookProvider` that records
// `Span`s with OTel GenAI semantic-convention names and attributes, and hands
// them to a callback or exports them as OTLP/JSON that a host can POST itself.
//
// Nothing here touches the network, writes a file, or starts a background task.
// On a phone that matters more than a protocol: `recordContent` is off by
// default, so no prompt or answer leaves the process inside a span.

/// One span, shaped like an OpenTelemetry span (ids are 32/16 hex characters,
/// so a host can forward them to a real collector unchanged).
public struct Span: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable { case `internal`, client }
    public enum Status: String, Sendable, Codable, Hashable { case unset, ok, error }

    public var id: String
    public var traceId: String
    public var parentId: String?
    /// OTel GenAI span name: `invoke_agent <agent>`, `chat <model>`, `execute_tool <tool>`.
    public var name: String
    public var kind: Kind
    public var startTime: Date
    public var endTime: Date?
    public var attributes: [String: JSONValue]
    public var events: [SpanEvent]
    public var status: Status
    public var statusMessage: String?

    public init(id: String = Span.makeSpanId(), traceId: String, parentId: String? = nil,
                name: String, kind: Kind = .internal, startTime: Date = Date(),
                endTime: Date? = nil, attributes: [String: JSONValue] = [:],
                events: [SpanEvent] = [], status: Status = .unset, statusMessage: String? = nil) {
        self.id = id; self.traceId = traceId; self.parentId = parentId; self.name = name; self.kind = kind
        self.startTime = startTime; self.endTime = endTime; self.attributes = attributes
        self.events = events; self.status = status; self.statusMessage = statusMessage
    }

    public var durationMs: Double? { endTime.map { $0.timeIntervalSince(startTime) * 1000 } }
    public static func makeTraceId() -> String { hex(16) }
    public static func makeSpanId() -> String { hex(8) }
    private static func hex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// A point in time inside a span (OTel GenAI events: `gen_ai.user.message`, …).
public struct SpanEvent: Sendable, Hashable, Codable {
    public var name: String
    public var timestamp: Date
    public var attributes: [String: JSONValue]
    public init(name: String, timestamp: Date = Date(), attributes: [String: JSONValue] = [:]) {
        self.name = name; self.timestamp = timestamp; self.attributes = attributes
    }
}

/// The attribute names loopl writes, from the OTel GenAI semantic conventions.
/// Kept as constants so a host can match on them instead of on string literals.
public enum SpanAttribute {
    public static let system = "gen_ai.system"                       // "loopl"
    public static let operation = "gen_ai.operation.name"            // invoke_agent | chat | execute_tool
    public static let agentName = "gen_ai.agent.name"
    public static let requestModel = "gen_ai.request.model"
    public static let inputTokens = "gen_ai.usage.input_tokens"
    public static let outputTokens = "gen_ai.usage.output_tokens"
    public static let ttftMs = "gen_ai.server.time_to_first_token"
    public static let finishReason = "gen_ai.response.finish_reasons"
    public static let toolName = "gen_ai.tool.name"
    public static let toolCallId = "gen_ai.tool.call.id"
    public static let toolArguments = "gen_ai.tool.call.arguments"   // only when recordContent
    public static let toolResult = "gen_ai.tool.call.result"         // only when recordContent
    public static let inputMessages = "gen_ai.input.messages"        // only when recordContent
    public static let outputMessages = "gen_ai.output.messages"      // only when recordContent
    /// loopl's own numbers (no OTel convention exists for on-device decode speed).
    public static let tokensPerSecond = "loopl.tokens_per_second"
    public static let runtime = "loopl.runtime"
    public static let cycle = "loopl.event_loop.cycle"
}

/// Turns an agent's hooks into spans.
///
///     let tracer = Tracer(agentName: "chat") { span in print(span.name, span.durationMs ?? 0) }
///     let agent = Agent(model: model, tools: tools, hooks: [tracer])
///     …
///     let json = tracer.otlpJSON()        // OTLP/JSON, ready to POST to a collector
///
/// One root span per invocation, a `chat` child per model call, an
/// `execute_tool` child per tool (concurrent tools are matched by `toolUseId`,
/// so parallel calls nest correctly).
public final class Tracer: HookProvider, @unchecked Sendable {
    public struct Options: Sendable {
        /// Put prompts, answers, tool arguments and tool results into span
        /// attributes. Off by default: a span is diagnostics, not a transcript.
        public var recordContent: Bool
        /// How many finished spans to keep in memory (FIFO). 0 = keep none (callback only).
        public var keep: Int
        public init(recordContent: Bool = false, keep: Int = 512) {
            self.recordContent = recordContent; self.keep = keep
        }
    }

    public let agentName: String
    public let options: Options
    /// Called for every span as it ends (also when `keep` is 0).
    public let onSpanEnd: (@Sendable (Span) -> Void)?

    private let lock = NSLock()
    private var finished: [Span] = []
    private var traceId = Span.makeTraceId()
    private var root: Span?
    private var model: Span?
    private var toolSpans: [String: Span] = [:]
    private var cycle = 0

    public init(agentName: String = "agent", options: Options = .init(), onSpanEnd: (@Sendable (Span) -> Void)? = nil) {
        self.agentName = agentName; self.options = options; self.onSpanEnd = onSpanEnd
    }

    /// Spans finished so far, oldest first.
    public var spans: [Span] { lock.withLock { finished } }
    /// The trace the current (or last) invocation belongs to.
    public var currentTraceId: String { lock.withLock { traceId } }
    public func reset() { lock.withLock { finished = []; root = nil; model = nil; toolSpans = [:]; cycle = 0 } }

    // MARK: hooks

    public func registerHooks(_ registry: HookRegistry) {
        registry.addCallback(BeforeInvocationEvent.self) { [self] event in
            startRoot(input: event.messages)
        }
        registry.addCallback(BeforeModelCallEvent.self) { [self] event in
            startModel(projectedInputTokens: event.projectedInputTokens,
                       contextWindow: event.contextWindow,
                       messages: event.messages,
                       systemPrompt: event.systemPrompt)
        }
        registry.addCallback(AfterModelCallEvent.self) { [self] event in
            endModel(stopReason: event.stopResponse?.stopReason,
                     message: event.stopResponse?.message,
                     error: event.error,
                     retry: event.retry)
        }
        registry.addCallback(BeforeToolCallEvent.self) { [self] event in
            startTool(event.toolUse, known: event.selectedTool != nil)
        }
        registry.addCallback(AfterToolCallEvent.self) { [self] event in
            endTool(event.result)
        }
        registry.addCallback(MessageAddedEvent.self) { [self] event in
            addMessageEvent(event.message)
        }
        registry.addCallback(AfterInvocationEvent.self) { [self] event in
            endRoot(result: event.result, error: event.error)
        }
    }

    // MARK: span building

    private func startRoot(input: [Message]) {
        lock.withLock {
            guard root == nil else { return }       // a nested invocation shares the root
            traceId = Span.makeTraceId()
            cycle = 0
            var attributes: [String: JSONValue] = [
                SpanAttribute.system: "loopl",
                SpanAttribute.operation: "invoke_agent",
                SpanAttribute.agentName: .string(agentName),
            ]
            if options.recordContent { attributes[SpanAttribute.inputMessages] = Self.render(input) }
            root = Span(traceId: traceId, name: "invoke_agent \(agentName)", kind: .internal, attributes: attributes)
        }
    }

    private func startModel(projectedInputTokens: Int, contextWindow: Int, messages: [Message], systemPrompt: String?) {
        lock.withLock {
            cycle += 1
            var attributes: [String: JSONValue] = [
                SpanAttribute.system: "loopl",
                SpanAttribute.operation: "chat",
                SpanAttribute.cycle: .number(Double(cycle)),
                "gen_ai.request.context_window": .number(Double(contextWindow)),
                "loopl.projected_input_tokens": .number(Double(projectedInputTokens)),
            ]
            if options.recordContent {
                attributes[SpanAttribute.inputMessages] = Self.render(messages)
                if let systemPrompt { attributes["gen_ai.system_instructions"] = .string(systemPrompt) }
            }
            model = Span(traceId: traceId, parentId: root?.id, name: "chat", kind: .client, attributes: attributes)
        }
    }

    private func endModel(stopReason: StopReason?, message: Message?, error: (any Error)?, retry: Bool) {
        var ended: Span?
        lock.withLock {
            guard var span = model else { return }
            if let stopReason { span.attributes[SpanAttribute.finishReason] = .array([.string(stopReason.rawValue)]) }
            if retry { span.attributes["loopl.retry"] = .bool(true) }
            if let message, options.recordContent { span.attributes[SpanAttribute.outputMessages] = Self.render([message]) }
            if let message { span.attributes["gen_ai.response.tool_calls"] = .number(Double(message.toolUses.count)) }
            if let error {
                span.status = .error
                span.statusMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            } else {
                span.status = .ok
            }
            span.endTime = Date()
            model = nil
            ended = span
            keep(span)
        }
        if let ended { onSpanEnd?(ended) }
    }

    /// The runtime's measured numbers (tok/s, TTFT, token counts) arrive as an
    /// `AgentEvent.metrics`, not as a hook — feed them in from the stream
    /// consumer. They land on the open `chat` span; if the consumer is behind
    /// the loop (it reads an `AsyncStream`, so it usually is) they are written
    /// onto the most recent `chat` span instead, never dropped.
    public func record(_ metrics: Metrics, runtime: RuntimeKind? = nil, modelId: String? = nil) {
        func apply(_ span: inout Span) {
            span.attributes[SpanAttribute.inputTokens] = .number(Double(metrics.promptTokens))
            span.attributes[SpanAttribute.outputTokens] = .number(Double(metrics.generatedTokens))
            if metrics.ttftMs > 0 { span.attributes[SpanAttribute.ttftMs] = .number(metrics.ttftMs) }
            if metrics.tokensPerSecond > 0 { span.attributes[SpanAttribute.tokensPerSecond] = .number(metrics.tokensPerSecond) }
            if let runtime { span.attributes[SpanAttribute.runtime] = .string(runtime.rawValue) }
            if let modelId { span.attributes[SpanAttribute.requestModel] = .string(modelId) }
            if metrics.estimated { span.attributes["loopl.tokens_estimated"] = .bool(true) }
        }
        lock.withLock {
            if var span = model {
                apply(&span); model = span; return
            }
            if let index = finished.lastIndex(where: { $0.name == "chat" }) {
                apply(&finished[index])
            }
        }
    }

    private func startTool(_ use: ToolUse, known: Bool) {
        lock.withLock {
            var attributes: [String: JSONValue] = [
                SpanAttribute.system: "loopl",
                SpanAttribute.operation: "execute_tool",
                SpanAttribute.toolName: .string(use.name),
                SpanAttribute.toolCallId: .string(use.toolUseId),
            ]
            if !known { attributes["loopl.tool.unknown"] = .bool(true) }
            if options.recordContent { attributes[SpanAttribute.toolArguments] = .object(use.input) }
            toolSpans[use.toolUseId] = Span(traceId: traceId, parentId: root?.id,
                                            name: "execute_tool \(use.name)", kind: .internal, attributes: attributes)
        }
    }

    private func endTool(_ result: ToolResult) {
        var ended: Span?
        lock.withLock {
            guard var span = toolSpans.removeValue(forKey: result.toolUseId) else { return }
            span.status = result.isError ? .error : .ok
            if result.isError { span.statusMessage = result.content }
            span.attributes["loopl.tool.duration_ms"] = .number(result.durationMs)
            if options.recordContent { span.attributes[SpanAttribute.toolResult] = .string(result.content) }
            span.endTime = Date()
            ended = span
            keep(span)
        }
        if let ended { onSpanEnd?(ended) }
    }

    private func addMessageEvent(_ message: Message) {
        lock.withLock {
            guard root != nil else { return }
            var attributes: [String: JSONValue] = ["gen_ai.message.role": .string(message.role.rawValue)]
            if options.recordContent, !message.text.isEmpty { attributes["content"] = .string(message.text) }
            let name = message.hasToolResult ? "gen_ai.tool.message" : "gen_ai.\(message.role.rawValue).message"
            root?.events.append(SpanEvent(name: name, attributes: attributes))
        }
    }

    private func endRoot(result: AgentResult?, error: String?) {
        var ended: [Span] = []
        lock.withLock {
            // a model call or tool still open means the invocation threw mid-flight
            if var span = model {
                span.status = .error; span.statusMessage = error ?? "invocation ended"; span.endTime = Date()
                model = nil; ended.append(span); keep(span)
            }
            for (id, var span) in toolSpans {
                span.status = .error; span.statusMessage = error ?? "invocation ended"; span.endTime = Date()
                toolSpans[id] = nil; ended.append(span); keep(span)
            }
            guard var span = root else { return }
            if let result {
                span.attributes[SpanAttribute.finishReason] = .array([.string(result.stopReason.rawValue)])
                span.attributes[SpanAttribute.inputTokens] = .number(Double(result.metrics.accumulatedUsage.inputTokens))
                span.attributes[SpanAttribute.outputTokens] = .number(Double(result.metrics.accumulatedUsage.outputTokens))
                span.attributes["loopl.event_loop.cycles"] = .number(Double(result.metrics.cycleCount))
                span.attributes["loopl.tool_calls"] = .number(Double(result.metrics.toolCallCount))
                if options.recordContent { span.attributes[SpanAttribute.outputMessages] = Self.render([result.message]) }
            }
            if let error { span.status = .error; span.statusMessage = error } else { span.status = .ok }
            span.endTime = Date()
            root = nil
            ended.append(span)
            keep(span)
        }
        for span in ended { onSpanEnd?(span) }
    }

    private func keep(_ span: Span) {
        guard options.keep > 0 else { return }
        finished.append(span)
        if finished.count > options.keep { finished.removeFirst(finished.count - options.keep) }
    }

    private static func render(_ messages: [Message]) -> JSONValue {
        .array(messages.map { m in
            .object(["role": .string(m.role.rawValue), "content": .string(m.text)])
        })
    }

    // MARK: export

    /// The kept spans as OTLP/JSON (`resourceSpans`), the body an OTel
    /// collector accepts at `POST /v1/traces`. loopl does not send it: a host
    /// that wants to export decides when, where and whether at all.
    public func otlpJSON(serviceName: String = "loopl") -> JSONValue {
        let spans = self.spans
        return .object([
            "resourceSpans": .array([
                .object([
                    "resource": .object(["attributes": .array([
                        .object(["key": "service.name", "value": .object(["stringValue": .string(serviceName)])]),
                    ])]),
                    "scopeSpans": .array([
                        .object([
                            "scope": .object(["name": "loopl"]),
                            "spans": .array(spans.map(Self.otlpSpan)),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    private static func otlpSpan(_ span: Span) -> JSONValue {
        var out: [String: JSONValue] = [
            "traceId": .string(span.traceId),
            "spanId": .string(span.id),
            "name": .string(span.name),
            "kind": .number(span.kind == .client ? 3 : 1),
            "startTimeUnixNano": .string(nanos(span.startTime)),
            "attributes": .array(span.attributes.keys.sorted().map { key in
                .object(["key": .string(key), "value": otlpValue(span.attributes[key]!)])
            }),
            "status": .object(span.status == .unset ? [:] : [
                "code": .number(span.status == .ok ? 1 : 2),
                "message": .string(span.statusMessage ?? ""),
            ]),
        ]
        if let parent = span.parentId { out["parentSpanId"] = .string(parent) }
        if let end = span.endTime { out["endTimeUnixNano"] = .string(nanos(end)) }
        if !span.events.isEmpty {
            out["events"] = .array(span.events.map { e in
                .object(["name": .string(e.name), "timeUnixNano": .string(nanos(e.timestamp)),
                         "attributes": .array(e.attributes.keys.sorted().map { key in
                             .object(["key": .string(key), "value": otlpValue(e.attributes[key]!)])
                         })])
            })
        }
        return .object(out)
    }

    private static func nanos(_ date: Date) -> String {
        String(UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000))
    }
    private static func otlpValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return .object(["stringValue": .string(s)])
        case .bool(let b): return .object(["boolValue": .bool(b)])
        case .number(let n):
            return n == n.rounded() && abs(n) < 9e15
                ? .object(["intValue": .string(String(Int(n)))])
                : .object(["doubleValue": .number(n)])
        case .array(let a): return .object(["arrayValue": .object(["values": .array(a.map(otlpValue))])])
        case .object, .null: return .object(["stringValue": .string(value.compact)])
        }
    }
}
