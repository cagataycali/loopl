import Foundation

// Structured output — Strands `structured_output` in Swift. Strands hands a
// Pydantic model to the invocation, registers a tool whose input IS the schema,
// forces tool choice, and retries once with a "format the previous response"
// prompt when the model answers in prose instead. loopl does the same with
// `Decodable` + a derived JSON schema (`JSONSchema.derive`), and — because a
// local model has no `tool_choice` field to set — forces by making the
// structured tool the ONLY tool of the forced pass and saying so in the prompt.
//
// The loop itself is untouched: the tool captures and decodes the value, and a
// `BeforeModelCall` hook ends the invocation as soon as the value is in, so no
// extra generation is spent summarising what the caller already has.

/// Knobs for one structured call. Defaults are the on-device sane ones.
public struct StructuredOutputOptions: Sendable {
    /// Override the derived schema (or supply one for a type derivation cannot see).
    public var schema: JSONValue?
    /// Per-property descriptions by path (`"city"`, `"address.city"`) — merged into the derived schema.
    public var describe: [String: String]
    /// Tool name the model must call. Default `structured_output`.
    public var toolName: String
    /// Tool description. Default mentions the Swift type.
    public var toolDescription: String?
    /// Keep the agent's other tools available in the first pass (the model may
    /// need them to find the answer). The forced pass always offers this tool only.
    public var withTools: Bool
    /// The nudge used for the forced pass (Strands: "You must format the previous response as structured output.").
    public var forcePrompt: String
    /// How many malformed calls to feed back to the model before giving up. Default 1.
    public var maxRepairs: Int
    /// The assistant text written to history when the loop is ended early with the value in hand.
    public var completionNote: String
    /// Restore `agent.messages` to its pre-call state when the call returns —
    /// a structured query then leaves no trace in the chat. Default `false` (Strands keeps it).
    public var discardHistory: Bool
    /// Dates are ISO-8601 (what the derived schema advertises) and keys are decoded as written.
    public var dateStrategy: JSONDecoder.DateDecodingStrategy

    public init(schema: JSONValue? = nil,
                describe: [String: String] = [:],
                toolName: String = "structured_output",
                toolDescription: String? = nil,
                withTools: Bool = true,
                forcePrompt: String = "You must return the answer by calling the structured_output tool now. Do not write prose.",
                maxRepairs: Int = 1,
                completionNote: String = "Returned structured output.",
                discardHistory: Bool = false,
                dateStrategy: JSONDecoder.DateDecodingStrategy = .iso8601) {
        self.schema = schema; self.describe = describe; self.toolName = toolName
        self.toolDescription = toolDescription; self.withTools = withTools; self.forcePrompt = forcePrompt
        self.maxRepairs = maxRepairs; self.completionNote = completionNote
        self.discardHistory = discardHistory; self.dateStrategy = dateStrategy
    }
}

/// The value plus what it cost: the final `AgentResult` (metrics, stop reason),
/// whether the forced pass was needed, and how many malformed calls were repaired.
public struct StructuredRun<T: Sendable>: Sendable {
    public var value: T
    public var result: AgentResult
    public var forced: Bool
    public var repairs: Int
    public init(value: T, result: AgentResult, forced: Bool, repairs: Int) {
        self.value = value; self.result = result; self.forced = forced; self.repairs = repairs
    }
}

/// Structured output could not be produced.
public enum StructuredOutputError: LocalizedError, Sendable {
    /// The model never called the tool, in the normal pass or the forced one.
    case notCalled(type: String, attempts: Int, lastText: String)
    /// It called it, but the input never decoded — `reason` is the last decoder complaint.
    case decodingFailed(type: String, reason: String, repairs: Int)

    public var errorDescription: String? {
        switch self {
        case .notCalled(let type, let attempts, let lastText):
            return "the model did not call the structured_output tool for \(type) in \(attempts) attempt(s). Last answer: \"\(lastText.prefix(120))\""
        case .decodingFailed(let type, let reason, let repairs):
            return "the model's structured_output input did not decode as \(type) after \(repairs) repair attempt(s): \(reason)"
        }
    }
}

// MARK: - the tool

/// The tool whose arguments ARE the answer (Strands `StructuredOutputTool`).
/// Calling it decodes the model's JSON into `T`; a decoding failure is returned
/// to the model as an error tool result, which is how repair happens.
public struct StructuredOutputTool<T: Decodable & Sendable>: Tool {
    public let name: String
    public let description: String
    public let parameters: JSONValue
    let sink: StructuredSink<T>
    let dateStrategy: JSONDecoder.DateDecodingStrategy

    public init(_ type: T.Type,
                name: String = "structured_output",
                description: String? = nil,
                schema: JSONValue? = nil,
                describe: [String: String] = [:],
                dateStrategy: JSONDecoder.DateDecodingStrategy = .iso8601,
                sink: StructuredSink<T> = StructuredSink<T>()) throws {
        self.name = name
        self.description = description ?? "Return the final answer as JSON matching this schema (a \(T.self)). Call this exactly once, as soon as you have the answer."
        self.parameters = try schema ?? JSONSchema.derive(type, describe: describe)
        self.sink = sink
        self.dateStrategy = dateStrategy
    }

    /// The decoder's complaint is the repair signal — `ToolValidation` must not pre-empt it.
    public var validatesOwnInput: Bool { true }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        do {
            let value = try Self.decode(args, dateStrategy: dateStrategy)
            sink.store(value)
            return "ok"
        } catch {
            let reason = Self.describe(error)
            sink.fail(reason)
            throw ToolError("the arguments did not match the schema: \(reason). Call \(name) again with every required field, as plain JSON.")
        }
    }

    /// Decode the tool input. Two shapes are accepted because small models produce both:
    /// the object itself, and the object wrapped in a single key (`{"output": {…}}`,
    /// or a JSON *string* in one key).
    public static func decode(_ args: [String: JSONValue], dateStrategy: JSONDecoder.DateDecodingStrategy) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateStrategy
        func attempt(_ json: JSONValue) throws -> T {
            try decoder.decode(T.self, from: Data(json.compact.utf8))
        }
        do {
            return try attempt(.object(args))
        } catch let first {
            if args.count == 1, let only = args.values.first {
                if let text = only.stringValue, let parsed = JSONValue.parse(text), (try? attempt(parsed)) != nil {
                    return try attempt(parsed)
                }
                if let unwrapped = try? attempt(only) { return unwrapped }
            }
            throw first
        }
    }

    static func describe(_ error: any Error) -> String {
        guard let e = error as? DecodingError else { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        switch e {
        case .keyNotFound(let key, _): return "missing required field \"\(key.stringValue)\""
        case .typeMismatch(let type, let ctx): return "wrong type for \"\(path(ctx))\" (expected \(type))"
        case .valueNotFound(let type, let ctx): return "null for \"\(path(ctx))\" (expected \(type))"
        case .dataCorrupted(let ctx): return ctx.debugDescription.isEmpty ? "malformed JSON" : ctx.debugDescription
        @unknown default: return "\(e)"
        }
    }
    private static func path(_ ctx: DecodingError.Context) -> String {
        ctx.codingPath.map(\.stringValue).joined(separator: ".")
    }
}

/// Where the decoded value lands. A class so the tool (a value type the agent
/// copies) and the caller see the same slot.
public final class StructuredSink<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    private var _error: String?
    private var _failures = 0
    public init() {}
    public var value: T? { lock.withLock { _value } }
    public var lastError: String? { lock.withLock { _error } }
    public var failures: Int { lock.withLock { _failures } }
    func store(_ v: T) { lock.withLock { _value = v; _error = nil } }
    func fail(_ reason: String) { lock.withLock { _error = reason; _failures += 1 } }
}

// MARK: - stopping the loop without touching it

/// Installed once per `HookRegistry`: while a structured call is running it
/// cancels the NEXT model call as soon as the value is in (or the repair budget
/// is spent), so the invocation ends with `endTurn` instead of spending another
/// generation. Idle at all other times.
final class StructuredCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var stopNote: String?
    private var active = false

    private var note = "Returned structured output."
    /// Asked after every tool call: "is the value in (or the repair budget spent)?".
    private var shouldStop: (@Sendable () -> Bool)?

    func begin(note: String, shouldStop: @escaping @Sendable () -> Bool) {
        lock.withLock { active = true; stopNote = nil; self.note = note; self.shouldStop = shouldStop }
    }
    func end() { lock.withLock { active = false; stopNote = nil; shouldStop = nil } }

    func register(_ registry: HookRegistry) {
        // Runs INSIDE the loop, right after each tool call, so the decision is
        // made before the loop recurses instead of racing a stream consumer.
        registry.addCallback(AfterToolCallEvent.self) { [self] _ in
            lock.withLock { if active, shouldStop?() == true { stopNote = note } }
        }
        registry.addCallback(BeforeModelCallEvent.self) { [self] event in
            let note = lock.withLock { active ? stopNote : nil }
            if let note { event.cancel = note }
        }
    }
}

enum StructuredHookInstaller {
    private final class WeakBox { weak var value: StructuredCoordinator?; init(_ v: StructuredCoordinator) { value = v } }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [ObjectIdentifier: WeakBox] = [:]

    /// The coordinator for this registry — registered on first use. The registry
    /// retains the callback (and thus the coordinator), the table only holds it weakly,
    /// so it dies with the agent and no identifier can be reused behind our back.
    static func coordinator(for registry: HookRegistry) -> StructuredCoordinator {
        let key = ObjectIdentifier(registry)
        return lock.withLock {
            if let existing = table[key]?.value { return existing }
            let fresh = StructuredCoordinator()
            fresh.register(registry)
            table[key] = WeakBox(fresh)
            table = table.filter { $0.value.value != nil }
            return fresh
        }
    }
}

// MARK: - the API

public extension Agent {
    /// Ask for a value instead of prose (Strands `structured_output`):
    ///
    ///     struct Weather: Codable, Sendable { let city: String; let celsius: Int }
    ///     let w = try await agent.structured(As: Weather.self, prompt: "weather in Istanbul")
    ///
    /// The schema is derived from `Weather` (`JSONSchema.derive`) and offered as
    /// the `structured_output` tool. The model may use the agent's other tools
    /// first; when it answers in prose instead of calling it, the call is
    /// retried once with only that tool available (loopl's stand-in for
    /// `tool_choice: any`, which no on-device runtime exposes). A malformed
    /// input is handed back to the model as an error result — `maxRepairs`
    /// bounds that — and then thrown as `StructuredOutputError`.
    @discardableResult
    func structured<T: Decodable & Sendable>(As type: T.Type,
                                             prompt: String? = nil,
                                             options: StructuredOutputOptions = .init()) async throws -> T {
        try await structuredRun(As: type, prompt: prompt, options: options).value
    }

    /// `structured(As:)` plus what it cost (metrics, whether forcing was needed, repairs).
    func structuredRun<T: Decodable & Sendable>(As type: T.Type,
                                                prompt: String? = nil,
                                                options: StructuredOutputOptions = .init()) async throws -> StructuredRun<T> {
        let sink = StructuredSink<T>()
        let tool = try StructuredOutputTool(type,
                                            name: options.toolName,
                                            description: options.toolDescription,
                                            schema: options.schema,
                                            describe: options.describe,
                                            dateStrategy: options.dateStrategy,
                                            sink: sink)
        let coordinator = StructuredHookInstaller.coordinator(for: hooks)
        let savedTools = tools
        let savedMessages = messages
        let maxRepairs = options.maxRepairs
        let shouldStop: @Sendable () -> Bool = { sink.value != nil || sink.failures > maxRepairs }
        coordinator.begin(note: options.completionNote, shouldStop: shouldStop)
        defer {
            coordinator.end()
            setTools(savedTools)
            if options.discardHistory { setMessages(savedMessages) }
        }

        setTools(options.withTools ? savedTools + [tool] : [tool])
        var result = try await invoke(prompt.map { Agent.Input.text($0) } ?? .continue)
        if let value = sink.value {
            return StructuredRun(value: value, result: result, forced: false, repairs: sink.failures)
        }
        if sink.failures > options.maxRepairs, let reason = sink.lastError {
            throw StructuredOutputError.decodingFailed(type: "\(type)", reason: reason, repairs: sink.failures)
        }

        // Forced pass: this tool only, and a prompt that says so.
        coordinator.begin(note: options.completionNote, shouldStop: shouldStop)
        setTools([tool])
        result = try await invoke(.text(options.forcePrompt))
        if let value = sink.value {
            return StructuredRun(value: value, result: result, forced: true, repairs: sink.failures)
        }
        if let reason = sink.lastError {
            throw StructuredOutputError.decodingFailed(type: "\(type)", reason: reason, repairs: sink.failures)
        }
        throw StructuredOutputError.notCalled(type: "\(type)", attempts: 2, lastText: result.text)
    }

}
