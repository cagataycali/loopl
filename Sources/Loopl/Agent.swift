import Foundation

/// Everything a UI needs to show each step of the loop.
public enum AgentEvent: Sendable {
    case iterationStarted(Int)
    case text(String)                        // streamed assistant text (current iteration)
    case metrics(Metrics)
    case assistantMessage(Message)           // final assistant turn of an iteration (text + parsed calls)
    case toolStarted(ToolCall)
    case toolFinished(ToolResult)
    case warning(String)                     // loop detector & co — informational, never stops the loop
    case finished(iterations: Int, reason: FinishReason)
}

public enum FinishReason: String, Sendable { case answered, budget, cancelled }

/// Optional caps. The DEFAULT is unlimited: the loop runs until the model
/// stops calling tools or the caller cancels. Set a field to cap it.
public struct Budget: Sendable, Hashable {
    public var maxIterations: Int? = nil
    public var maxToolCalls: Int? = nil
    public var maxWallTime: TimeInterval? = nil
    public var maxGeneratedTokens: Int? = nil
    public init(maxIterations: Int? = nil, maxToolCalls: Int? = nil, maxWallTime: TimeInterval? = nil, maxGeneratedTokens: Int? = nil) {
        self.maxIterations = maxIterations; self.maxToolCalls = maxToolCalls; self.maxWallTime = maxWallTime; self.maxGeneratedTokens = maxGeneratedTokens
    }
    public static let unlimited = Budget()

    func exceeded(iterations: Int, toolCalls: Int, elapsed: TimeInterval, generated: Int) -> String? {
        if let m = maxIterations, iterations > m { return "max iterations (\(m)) reached" }
        if let m = maxToolCalls, toolCalls > m { return "max tool calls (\(m)) reached" }
        if let m = maxWallTime, elapsed > m { return "wall time (\(Int(m)) s) exceeded" }
        if let m = maxGeneratedTokens, generated > m { return "generated tokens (\(m)) exceeded" }
        return nil
    }
}

/// Warns when the model keeps issuing the identical tool call (same name +
/// arguments) — a classic stuck loop. It only WARNS (`AgentEvent.warning`);
/// stopping is the caller's decision (cancel) or the `Budget`'s.
public struct LoopDetector: Sendable, Hashable {
    public var threshold: Int
    public init(threshold: Int = 3) { self.threshold = threshold }
    var history: [String] = []
    mutating func observe(_ call: ToolCall) -> String? {
        let key = call.name + ":" + JSONValue.object(call.arguments).compact
        history.append(key)
        let run = history.reversed().prefix { $0 == key }.count
        if run >= threshold { return "tool '\(call.name)' called \(run)× in a row with identical arguments — the model may be stuck; stop it if this keeps going" }
        return nil
    }
}

public struct AgentConfig: Sendable {
    public var budget: Budget = .unlimited
    public var loopDetector: LoopDetector? = LoopDetector()
    public var family: ToolFamily = .hermes
    public var params = GenerationParams()
    public init() {}
}

/// The result of one `agent("prompt")` call (Strands: `AgentResult`).
public struct AgentResult: Sendable {
    public var text: String
    public var iterations: Int
    public var toolResults: [ToolResult]
    public var metrics: Metrics
    public var reason: FinishReason
}

/// The strands algorithm: stream → parse tool calls → run tools → append →
/// recurse until the model answers without a call, the budget caps it, or
/// the caller cancels. Pure Swift: it only knows `Model` and `Tool`.
///
///     let agent = Agent(model: mlx, tools: [CurrentTimeTool(), CalculatorTool()], systemPrompt: "Be brief.")
///     let answer = try await agent("what time is it in Istanbul and what is 23*47?")
///     for try await event in agent.stream("…") { … }
public actor Agent {
    public let model: any Model
    public var tools: [any Tool]
    public var config: AgentConfig
    /// The conversation so far (system prompt first). Mutable so a host can trim/condense it.
    public var messages: [Message]

    public init(model: any Model, tools: [any Tool] = [], systemPrompt: String? = nil, config: AgentConfig = AgentConfig()) {
        self.model = model
        self.tools = tools
        self.config = config
        self.messages = systemPrompt.map { [.system($0)] } ?? []
    }

    public func reset(systemPrompt: String? = nil) {
        messages = systemPrompt.map { [.system($0)] } ?? messages.filter { if case .system = $0 { return true }; return false }
    }

    /// Strands-style call: run to completion, return the final text.
    public func callAsFunction(_ prompt: String) async throws -> AgentResult {
        var text = ""; var results: [ToolResult] = []; var metrics = Metrics(); var iterations = 0; var reason = FinishReason.answered
        for try await e in stream(prompt) {
            switch e {
            case .assistantMessage(let m): text = m.text
            case .toolFinished(let r): results.append(r)
            case .metrics(let m): metrics = m
            case .finished(let n, let r): iterations = n; reason = r
            default: break
            }
        }
        return AgentResult(text: text, iterations: iterations, toolResults: results, metrics: metrics, reason: reason)
    }

    /// Append a user turn and run the loop, streaming every step. New
    /// assistant/tool messages are committed to `messages` as they happen.
    public nonisolated func stream(_ prompt: String) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.append(.user(prompt))
                await self.run(continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func append(_ m: Message) { messages.append(m) }

    private func run(_ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async {
        let parser = ToolCallParser(family: config.family)
        let toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var detector = config.loopDetector
        let started = Date()
        var iteration = 0, toolCalls = 0, generated = 0
        do {
            while true {
                iteration += 1
                if let why = config.budget.exceeded(iterations: iteration, toolCalls: toolCalls, elapsed: Date().timeIntervalSince(started), generated: generated) {
                    continuation.yield(.warning(why))
                    continuation.yield(.finished(iterations: iteration - 1, reason: .budget)); continuation.finish(); return
                }
                try Task.checkCancellation()
                continuation.yield(.iterationStarted(iteration))

                var text = ""
                var nativeCalls: [ToolCall] = []
                for try await event in model.stream(messages: messages, tools: tools, params: config.params) {
                    try Task.checkCancellation()
                    switch event {
                    case .text(let t): text += t; continuation.yield(.text(t))
                    case .toolCall(let c): nativeCalls.append(c)
                    case .metrics(let m): generated = max(generated, m.generatedTokens); continuation.yield(.metrics(m))
                    }
                }

                let parsed = parser.parse(text)
                // A runtime may both emit a native call AND leave the markup in the text — keep one.
                let calls = nativeCalls + parsed.calls.filter { p in !nativeCalls.contains { $0.name == p.name && $0.arguments == p.arguments } }
                let assistant = Message.assistant(text: parsed.text, toolCalls: calls)
                messages.append(assistant)
                continuation.yield(.assistantMessage(assistant))

                if calls.isEmpty {
                    continuation.yield(.finished(iterations: iteration, reason: .answered)); continuation.finish(); return
                }

                for call in calls {
                    try Task.checkCancellation()
                    toolCalls += 1
                    if let warning = detector?.observe(call) { continuation.yield(.warning(warning)) }
                    continuation.yield(.toolStarted(call))
                    let t0 = Date()
                    var content: String; var isError = false
                    if let tool = toolsByName[call.name] {
                        do { content = try await tool.call(call.arguments) }
                        catch { content = "error: \(error.localizedDescription)"; isError = true }
                    } else {
                        content = "error: unknown tool '\(call.name)'. Available: \(toolsByName.keys.sorted().joined(separator: ", "))"; isError = true
                    }
                    let result = ToolResult(callId: call.id, name: call.name, content: content, isError: isError, durationMs: Date().timeIntervalSince(t0) * 1000)
                    messages.append(result.message)
                    continuation.yield(.toolFinished(result))
                }
            }
        } catch is CancellationError {
            continuation.yield(.finished(iterations: iteration, reason: .cancelled)); continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
