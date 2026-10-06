import Foundation

// Strands `agent/agent.py` (`__call__`, `stream_async`, `_run_loop`,
// `_execute_event_loop_cycle`) and `event_loop/event_loop.py`
// (`event_loop_cycle`, `recurse_event_loop`, `_handle_model_execution`,
// `_handle_tool_execution`) — one actor, same control flow, no caps.

/// Strands `TypedEvent`s as one enum. Everything a UI needs to show each step.
public enum AgentEvent: Sendable {
    case initEventLoop                                           // InitEventLoopEvent (first cycle of an invocation)
    case startEventLoop(cycle: Int)                              // StartEvent + StartEventLoopEvent
    case modelStreamChunk(StreamEvent)                           // ModelStreamChunkEvent (raw)
    case text(String)                                            // TextStreamEvent
    case reasoning(String)                                       // ReasoningTextStreamEvent
    case toolUseStream(name: String, toolUseId: String, partialInput: String)   // ToolUseStreamEvent
    case modelMessage(Message)                                   // ModelMessageEvent (assembled assistant turn, appended)
    case throttle(delay: TimeInterval)                           // EventLoopThrottleEvent (retry backoff)
    case approvalRequested(ApprovalRequest)                      // loopl: a tool call is suspended until `resolve(approval:)` (HITL)
    case approvalResolved(id: String, ApprovalDecision)          // loopl: the human (or the timeout) answered
    case toolStarted(ToolUse)                                    // loopl: the tool is about to run (after BeforeToolCall hooks + approval)
    case toolResult(ToolResult)                                  // ToolResultEvent
    case toolResultMessage(Message)                              // ToolResultMessageEvent (appended)
    case metrics(Metrics)                                        // loopl: runtime numbers (debug sheet)
    case forceStop(String)                                       // ForceStopEvent
    case result(AgentResult)                                     // AgentResultEvent — always the last event
}

/// Strands `EventLoopMetrics` (the parts that mean something on-device).
public struct EventLoopMetrics: Sendable, Hashable, Codable {
    public var cycleCount = 0
    public var toolCallCount = 0
    public var accumulatedUsage = Usage()
    public var accumulatedLatencyMs: Double = 0
    /// How many times a `ContextWindowOverflowError` was recovered by reducing
    /// context in this run (mirrors the maxTokens recovery; capped by
    /// `Agent.maxContextReductions`).
    public var contextReductionCount = 0
    /// The last runtime report (tok/s, TTFT, context) — for the debug sheet.
    public var last = Metrics()
    public init() {}
    mutating func update(_ m: Metrics) {
        accumulatedUsage += m.usage
        last = m
    }
}

/// Strands `AgentResult`.
public struct AgentResult: Sendable, Hashable {
    public var stopReason: StopReason
    public var message: Message
    public var metrics: EventLoopMetrics
    public init(stopReason: StopReason, message: Message, metrics: EventLoopMetrics) {
        self.stopReason = stopReason; self.message = message; self.metrics = metrics
    }
    /// Strands `str(result)`: the text blocks of the final message.
    public var text: String { message.text }
}

/// Strands `Agent`. Pure Swift: it only knows `Model` and `Tool`.
///
///     let agent = Agent(model: mlx, tools: [CurrentTimeTool(), CalculatorTool()], systemPrompt: "Be brief.")
///     let result = try await agent("what time is it in Istanbul and what is 23*47?")
///     for try await event in agent.stream("…") { … }
///
/// There is no iteration cap and no loop detector: the loop runs until the
/// model stops calling tools, the caller cancels the task, or the context
/// cannot be reduced any further (`ContextWindowOverflowError`).
public actor Agent {
    public let model: any Model
    public private(set) var tools: [any Tool]
    public private(set) var systemPrompt: String?
    /// The conversation (Strands `agent.messages`): user/assistant turns only, system prompt beside it.
    public private(set) var messages: [Message]
    public let hooks = HookRegistry()
    public let conversationManager: any ConversationManager
    public let toolExecutor: any ToolExecutor
    public let retryStrategy: ModelRetryStrategy?
    public private(set) var eventLoopMetrics = EventLoopMetrics()
    /// Human-in-the-loop: how long a suspended tool call waits for `resolve(approval:)` before it is denied.
    public let approvalTimeout: TimeInterval
    private var pending: [String: (request: ApprovalRequest, continuation: CheckedContinuation<ApprovalDecision, Never>)] = [:]
    /// Tool calls waiting for a human right now (a UI restores its cards from this).
    public var pendingApprovals: [ApprovalRequest] { pending.values.map(\.request).sorted { $0.id < $1.id } }

    /// - Parameters:
    ///   - conversationManager: default `SlidingWindowConversationManager()` — the only limiter.
    ///   - hooks: `HookProvider`s registered after the manager and the retry strategy.
    ///   - toolExecutor: default `ConcurrentToolExecutor()`.
    ///   - retryStrategy: default `ModelRetryStrategy()` (6 attempts, 4 s → 240 s). Pass `nil` to disable.
    ///   - approvalTimeout: a tool call waiting for `resolve(approval:)` is denied after this (default 120 s).
    public init(model: any Model,
                tools: [any Tool] = [],
                systemPrompt: String? = nil,
                messages: [Message] = [],
                conversationManager: any ConversationManager = SlidingWindowConversationManager(),
                hooks: [any HookProvider] = [],
                toolExecutor: any ToolExecutor = ConcurrentToolExecutor(),
                retryStrategy: ModelRetryStrategy? = ModelRetryStrategy(),
                approvalTimeout: TimeInterval = 120) {
        self.model = model
        self.approvalTimeout = approvalTimeout
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.conversationManager = conversationManager
        self.toolExecutor = toolExecutor
        self.retryStrategy = retryStrategy
        conversationManager.registerHooks(self.hooks)
        if let retryStrategy { self.hooks.addHook(retryStrategy) }
        for h in hooks { self.hooks.addHook(h) }
    }

    // MARK: configuration

    public func setTools(_ tools: [any Tool]) { self.tools = tools }
    public func setSystemPrompt(_ prompt: String?) { systemPrompt = prompt }
    /// Replace the history (a host restoring a session). No hooks fire.
    public func setMessages(_ messages: [Message]) { self.messages = messages }
    /// Put accumulated metrics back (restoring an `AgentCheckpoint` — see Checkpoint.swift).
    public func setEventLoopMetrics(_ metrics: EventLoopMetrics) { eventLoopMetrics = metrics }
    public func reset() { messages.removeAll(); eventLoopMetrics = EventLoopMetrics() }

    // MARK: human-in-the-loop

    /// Answer a suspended tool call (`AgentEvent.approvalRequested`). Returns false when nothing
    /// with that id is waiting (already answered, timed out, or cancelled).
    @discardableResult
    public func resolve(approval id: String, _ decision: ApprovalDecision) -> Bool {
        guard let entry = pending.removeValue(forKey: id) else {
            // Answered before the call reached its suspension point (a very fast UI): keep it for `awaitDecision`.
            if awaiting.contains(id) { early[id] = decision; return true }
            return false
        }
        entry.continuation.resume(returning: decision)
        return true
    }
    private var awaiting: Set<String> = []
    private var early: [String: ApprovalDecision] = [:]

    /// Suspend the current tool call until `resolve(approval:)`, the timeout, or task cancellation.
    /// Awaiting the continuation releases the actor, so the other tools of the message keep running.
    private func awaitDecision(_ request: ApprovalRequest) async -> ApprovalDecision {
        let id = request.id
        let timeout = approvalTimeout
        awaiting.remove(id)
        if let d = early.removeValue(forKey: id) { return d }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.resolve(approval: id, .deny(reason: "no answer within \(Int(timeout)) s"))
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<ApprovalDecision, Never>) in
                pending[id] = (request, c)
            }
        } onCancel: {
            Task { [weak self] in await self?.resolve(approval: id, .deny(reason: "cancelled")) }
        }
    }

    // MARK: Strands `__call__` / `invoke_async`

    /// Run to completion with a text prompt.
    public func callAsFunction(_ prompt: String) async throws -> AgentResult { try await invoke(.text(prompt)) }
    /// Run to completion with explicit messages (Strands accepts `Messages` too).
    public func callAsFunction(_ messages: [Message]) async throws -> AgentResult { try await invoke(.messages(messages)) }
    /// Continue from the current history without new input (Strands `agent()` with `prompt=None`,
    /// e.g. after `MaxTokensReachedError`).
    public func callAsFunction() async throws -> AgentResult { try await invoke(.continue) }

    public enum Input: Sendable { case text(String), messages([Message]), `continue` }

    public func invoke(_ input: Input) async throws -> AgentResult {
        var result: AgentResult?
        for try await e in stream(input) { if case .result(let r) = e { result = r } }
        guard let result else { throw EventLoopError(ModelError("event loop ended without a result")) }
        return result
    }

    // MARK: Strands `stream_async`

    public nonisolated func stream(_ prompt: String) -> AsyncThrowingStream<AgentEvent, Error> { stream(.text(prompt)) }
    public nonisolated func stream(_ messages: [Message]) -> AsyncThrowingStream<AgentEvent, Error> { stream(.messages(messages)) }

    public nonisolated func stream(_ input: Input) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await self.runLoop(input) { continuation.yield($0) }
                    continuation.yield(.result(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Strands `_run_loop`

    private func runLoop(_ input: Input, _ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> AgentResult {
        let newMessages: [Message]
        switch input {
        case .text(let t): newMessages = [.user(t)]
        case .messages(let m): newMessages = m
        case .continue: newMessages = []
        }
        var before = BeforeInvocationEvent(messages: newMessages)
        before = try await hooks.invoke(before)
        if let cancel = before.cancel {
            let m = Message.assistant(cancel.isEmpty ? "invocation denied by hook" : cancel)
            try await appendMessage(m)
            let result = AgentResult(stopReason: .endTurn, message: m, metrics: eventLoopMetrics)
            try await hooks.invoke(AfterInvocationEvent(result: result, error: nil))
            return result
        }
        for m in before.messages { try await appendMessage(m) }
        yield(.initEventLoop)
        do {
            let result = try await executeEventLoopCycle(yield)
            var msgs = messages
            conversationManager.applyManagement(&msgs)
            messages = msgs
            try await hooks.invoke(AfterInvocationEvent(result: result, error: nil))
            return result
        } catch {
            try? await hooks.invoke(AfterInvocationEvent(result: nil, error: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            throw error
        }
    }

    // MARK: Strands `_execute_event_loop_cycle` (overflow → reduce → retry)

    private func executeEventLoopCycle(_ yield: @Sendable @escaping (AgentEvent) -> Void,
                                       contextReductionAttempt: Int = 0) async throws -> AgentResult {
        do {
            return try await eventLoopCycle(yield)
        } catch let overflow as ContextWindowOverflowError {
            // Same shape as the maxTokens recovery: take the runtime's refusal,
            // repair the history, try again — once. A second overflow after a
            // successful reduction means the prompt cannot be made to fit, and
            // the caller gets a clear error instead of an endless retry.
            guard contextReductionAttempt < Self.maxContextReductions else {
                let detail = overflow.errorDescription ?? "context window exceeded"
                let message = "\(detail) — context was reduced \(contextReductionAttempt) time(s) and still does not fit the model's window"
                yield(.forceStop(message))
                throw ContextWindowOverflowError(message)
            }
            var msgs = messages
            try conversationManager.reduceContext(&msgs, error: overflow)   // throws if nothing can be removed
            messages = msgs
            eventLoopMetrics.contextReductionCount += 1
            return try await executeEventLoopCycle(yield, contextReductionAttempt: contextReductionAttempt + 1)
        }
    }

    /// How many times one run may recover from a context-window overflow by
    /// reducing context and retrying (Strands retries the reduced prompt; on
    /// a 4096-token runtime one reduction is enough or nothing will be).
    public static let maxContextReductions = 1

    // MARK: Strands `event_loop_cycle`

    private func eventLoopCycle(_ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> AgentResult {
        eventLoopMetrics.cycleCount += 1
        yield(.startEventLoop(cycle: eventLoopMetrics.cycleCount))

        let stopReason: StopReason
        let message: Message
        if let last = messages.last, last.role == .assistant, last.hasToolUse {
            // A previous run was cut off before its tools ran — resume there (Strands `_has_tool_use_in_latest_message`).
            stopReason = .toolUse; message = last
        } else {
            (stopReason, message) = try await handleModelExecution(yield)
            yield(.modelMessage(message))
        }

        if stopReason == .maxTokens {
            // The recovered partial message is already in history; the caller may `agent()` again to continue.
            throw MaxTokensReachedError(message: message)
        }
        if stopReason == .toolUse {
            return try await handleToolExecution(message, yield)
        }
        return AgentResult(stopReason: stopReason, message: message, metrics: eventLoopMetrics)
    }

    private func recurseEventLoop(_ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> AgentResult {
        try await eventLoopCycle(yield)
    }

    // MARK: Strands `_handle_model_execution` (hooks + retry loop around one stream)

    private func handleModelExecution(_ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> (StopReason, Message) {
        while true {
            try Task.checkCancellation()
            let specs = tools.map(\.toolSpec)
            let contextWindow = await model.contextWindow     // per-runtime: Apple FM 4096, MLX/GGUF their real ctx
            var before = BeforeModelCallEvent(messages: messages, systemPrompt: systemPrompt,
                                              projectedInputTokens: TokenEstimator.estimate(messages: messages, systemPrompt: systemPrompt, toolSpecs: specs),
                                              contextWindow: contextWindow)
            before = try await hooks.invoke(before)
            if before.messages != messages { messages = before.messages }     // e.g. the sliding window trimmed
            let system = before.systemPrompt

            if let cancel = before.cancel {
                let message = Message.assistant(cancel.isEmpty ? "model call denied by hook" : cancel)
                var after = AfterModelCallEvent(stopResponse: .init(stopReason: .endTurn, message: message), error: nil)
                after = try await hooks.invoke(after)
                if after.retry { continue }
                try await appendMessage(message)
                return (.endTurn, message)
            }

            do {
                var assembler = StreamAssembler()
                var cancelled = false
                do {
                    for try await chunk in model.stream(messages, toolSpecs: specs, systemPrompt: system) {
                        try Task.checkCancellation()
                        for e in assembler.feed(chunk) {
                            switch e {
                            case .chunk(let c): yield(.modelStreamChunk(c)); if case .metadata(let m) = c { yield(.metrics(m)) }
                            case .text(let t): yield(.text(t))
                            case .reasoning(let r): yield(.reasoning(r))
                            case .toolUse(let name, let id, let partial): yield(.toolUseStream(name: name, toolUseId: id, partialInput: partial))
                            }
                        }
                    }
                } catch is CancellationError {
                    cancelled = true
                }
                var stop = assembler.finish()
                if cancelled {
                    // Strands `process_stream` with cancel_signal set → stop_reason "cancelled".
                    stop.stopReason = .cancelled
                    if stop.message.content.isEmpty { stop.message = .assistant("Cancelled by user") }
                }
                var after = AfterModelCallEvent(stopResponse: .init(stopReason: stop.stopReason, message: stop.message), error: nil)
                after = try await hooks.invoke(after)
                if after.retry { eventLoopMetrics.update(stop.metrics); continue }
                var message = after.stopResponse?.message ?? stop.message
                let stopReason = after.stopResponse?.stopReason ?? stop.stopReason
                if stopReason == .maxTokens { message = recoverMessageOnMaxTokensReached(message) }
                try await appendMessage(message)
                eventLoopMetrics.update(stop.metrics)
                return (stopReason, message)
            } catch {
                var after = AfterModelCallEvent(stopResponse: nil, error: error)
                after = try await hooks.invoke(after)
                if let d = retryStrategy?.lastDelay { yield(.throttle(delay: d)) }
                if after.retry { continue }
                if !(error is ContextWindowOverflowError) {      // overflow is recovered one level up, silently (Strands yields ForceStop first)
                    yield(.forceStop((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                }
                throw error
            }
        }
    }

    // MARK: Strands `_handle_tool_execution`

    private func handleToolExecution(_ message: Message, _ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> AgentResult {
        let toolUses = message.toolUses
        var before = BeforeToolsEvent(message: message)
        before = try await hooks.invoke(before)
        let cancelMessage: String? = before.cancel.map { $0.isEmpty ? "Tool cancelled by hook" : $0 } ?? (Task.isCancelled ? "Tool execution cancelled" : nil)

        var results: [ToolResult]
        if let cancelMessage {
            results = toolUses.map { ToolResult.error($0, cancelMessage) }
            results.forEach { yield(.toolResult($0)) }
        } else {
            results = await toolExecutor.execute(toolUses,
                                                 run: { [self] use in await self.runTool(use, yield) },
                                                 emit: { yield(.toolResult($0)) })
        }

        var after = AfterToolsEvent(message: .toolResults(results))
        after = try await hooks.invoke(after)
        try await appendMessage(after.message)
        yield(.toolResultMessage(after.message))
        eventLoopMetrics.toolCallCount += toolUses.count

        if Task.isCancelled {
            return AgentResult(stopReason: .cancelled, message: message, metrics: eventLoopMetrics)
        }
        return try await recurseEventLoop(yield)
    }

    /// Strands `ToolExecutor._stream`: BeforeToolCall → run → AfterToolCall, never throws (errors become error results).
    private func runTool(_ use: ToolUse, _ yield: @Sendable @escaping (AgentEvent) -> Void) async -> ToolResult {
        let t0 = Date()
        let selected = tools.first { $0.name == use.name }
        var approval = selected?.requiresApproval(for: use.input)
        approval?.id = use.toolUseId; approval?.toolName = use.name
        if approval?.input.isEmpty == true { approval?.input = use.input }
        var before = BeforeToolCallEvent(toolUse: use, selectedTool: selected, approval: approval)
        do { before = try await hooks.invoke(before) } catch {
            return .error(use, "hook error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        var toolUse = before.toolUse
        var result: ToolResult
        var thrown: (any Error)?
        if let cancel = before.cancelTool {
            let msg = cancel.isEmpty ? "tool cancelled by user" : cancel
            result = .error(toolUse, msg)
            var after = AfterToolCallEvent(toolUse: toolUse, selectedTool: nil, result: result, cancelMessage: msg)
            after = (try? await hooks.invoke(after)) ?? after
            return after.result
        }
        if var request = before.approval {
            // Human-in-the-loop: suspend this call (and only this call) until a decision arrives.
            request.id = toolUse.toolUseId; request.toolName = toolUse.name
            if request.input.isEmpty { request.input = toolUse.input }
            awaiting.insert(request.id)
            yield(.approvalRequested(request))
            let decision = await awaitDecision(request)
            yield(.approvalResolved(id: request.id, decision))
            switch decision {
            case .approve: break
            case .approveEdited(let edited): toolUse.input = edited
            case .deny(let reason):
                let msg = "Tool call denied by the user" + (reason.map { ": \($0)" } ?? "") + ". Do not retry it; continue without it."
                result = .error(toolUse, msg, durationMs: Date().timeIntervalSince(t0) * 1000)
                var after = AfterToolCallEvent(toolUse: toolUse, selectedTool: before.selectedTool, result: result, cancelMessage: msg)
                after = (try? await hooks.invoke(after)) ?? after
                return after.result
            }
        }
        yield(.toolStarted(toolUse))
        if let tool = before.selectedTool {
            do {
                let out = try await tool.call(toolUse.input, images: messages.last(where: { $0.role == .user })?.images ?? [])
                result = ToolResult(toolUseId: toolUse.toolUseId, name: toolUse.name, status: .success, content: out.text,
                                    durationMs: Date().timeIntervalSince(t0) * 1000, images: out.images)
            } catch {
                thrown = error
                result = ToolResult(toolUseId: toolUse.toolUseId, name: toolUse.name, status: .error,
                                    content: "Error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")",
                                    durationMs: Date().timeIntervalSince(t0) * 1000)
            }
        } else {
            result = .error(toolUse, "Unknown tool: \(toolUse.name). Available tools: \(tools.map(\.name).sorted().joined(separator: ", "))",
                            durationMs: Date().timeIntervalSince(t0) * 1000)
        }
        var after = AfterToolCallEvent(toolUse: toolUse, selectedTool: before.selectedTool, result: result, error: thrown)
        after = (try? await hooks.invoke(after)) ?? after
        return after.result
    }

    // MARK: Strands `_append_messages` (+ MessageAddedEvent)

    private func appendMessage(_ m: Message) async throws {
        messages.append(m)
        try await hooks.invoke(MessageAddedEvent(message: m))
    }
}
