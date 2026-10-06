import Foundation

// `agent/agent.py` (`__call__`, `stream_async`, `_run_loop`,
// `_execute_event_loop_cycle`) and `event_loop/event_loop.py`
// (`event_loop_cycle`, `recurse_event_loop`, `_handle_model_execution`,
// `_handle_tool_execution`) — one actor, same control flow, no caps.

/// `TypedEvent`s as one enum. Everything a UI needs to show each step.
public enum AgentEvent: Sendable {
    case initEventLoop                                           // InitEventLoopEvent (first cycle of an invocation)
    case startEventLoop(cycle: Int)                              // StartEvent + StartEventLoopEvent
    case modelStreamChunk(StreamEvent)                           // ModelStreamChunkEvent (raw)
    case text(String)                                            // TextStreamEvent
    case textReplace(String)                                     // loopl: the assistant text streamed so far is now exactly this (cumulative-snapshot runtimes)
    case reasoning(String)                                       // ReasoningTextStreamEvent
    case toolUseStream(name: String, toolUseId: String, partialInput: String)   // ToolUseStreamEvent
    case modelMessage(Message)                                   // ModelMessageEvent (assembled assistant turn, appended)
    case throttle(delay: TimeInterval)                           // EventLoopThrottleEvent (retry backoff)
    case approvalRequested(ApprovalRequest)                      // loopl: a tool call is suspended until `resolve(approval:)` (HITL)
    case approvalResolved(id: String, ApprovalDecision)          // loopl: the human (or the timeout) answered
    case interruptRaised(Interrupt)                              // interrupt: a hook or a tool wants a human (approval is one of these)
    case interruptResolved(id: String, response: JSONValue)      // the human (or the timeout) answered the interrupt
    case toolStarted(ToolUse)                                    // loopl: the tool is about to run (after BeforeToolCall hooks + approval)
    case toolResult(ToolResult)                                  // ToolResultEvent
    case toolResultMessage(Message)                              // ToolResultMessageEvent (appended)
    case historyEdited(HistoryEdit)                              // loopl: the agent edited its own working context (manage_messages) — a UI shows a quiet marker
    case metrics(Metrics)                                        // loopl: runtime numbers (debug sheet)
    case forceStop(String)                                       // ForceStopEvent
    case result(AgentResult)                                     // AgentResultEvent — always the last event
}

/// `EventLoopMetrics` (the parts that mean something on-device).
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
    /// Usage baseline: the real prompt+output token count the runtime reported for the
    /// most recent model call. The next cycle's projected input is this plus an estimate of the
    /// messages added since, instead of re-estimating the whole transcript (0 before the first call).
    public var usageBaselineTokens = 0
    public init() {}
    mutating func update(_ m: Metrics) {
        accumulatedUsage += m.usage
        last = m
    }
}

/// `AgentResult`.
public struct AgentResult: Sendable, Hashable {
    public var stopReason: StopReason
    public var message: Message
    public var metrics: EventLoopMetrics
    /// `AgentResult.interrupts`: set when `stopReason == .interrupt` (only possible
    /// with `InterruptMode.stop`) — answer them and call `agent.resume(_:)`.
    public var interrupts: [Interrupt]
    public init(stopReason: StopReason, message: Message, metrics: EventLoopMetrics, interrupts: [Interrupt] = []) {
        self.stopReason = stopReason; self.message = message; self.metrics = metrics; self.interrupts = interrupts
    }
    /// `str(result)`: the text blocks of the final message.
    public var text: String { message.text }
}

/// `Agent`. Pure Swift: it only knows `Model` and `Tool`.
///
///     let agent = Agent(model: mlx, tools: [CurrentTimeTool(), CalculatorTool()], systemPrompt: "Be brief.")
///     let result = try await agent("what time is it in Istanbul and what is 23*47?")
///     for try await event in agent.stream("…") { … }
///
/// There is no iteration cap: the loop runs until the model stops calling
/// tools, the caller cancels the task, or the context cannot be reduced any
/// further (`ContextWindowOverflowError`). There is no repeat or loop
/// heuristic either: the loop trusts the model to read complete,
/// honest tool results (including errors) and decide what to call next.
public actor Agent {
    public let model: any Model
    public private(set) var tools: [any Tool]
    public private(set) var systemPrompt: String?
    /// The conversation (`agent.messages`): user/assistant turns only, system prompt beside it.
    public private(set) var messages: [Message]
    public let hooks = HookRegistry()
    public let conversationManager: any ConversationManager
    public let toolExecutor: any ToolExecutor
    public let retryStrategy: ModelRetryStrategy?
    public private(set) var eventLoopMetrics = EventLoopMetrics()
    /// `invocation_state["request_state"]`: scratch space hooks share across a cycle.
    /// `stopEventLoop = true` after tools ends the loop without calling the model again.
    public private(set) var requestState: [String: JSONValue] = [:]
    /// `_estimate_input_tokens`: the last assistant message whose usage the runtime
    /// actually measured, and that measurement. Only the messages after it need estimating —
    /// the system prompt and the tool specs are already inside the number.
    private var usageBaseline: (messageID: UUID, tokens: Int)?
    /// Human-in-the-loop: how long a suspended tool call waits for `resolve(approval:)` before it is denied.
    public let approvalTimeout: TimeInterval
    /// What a raised interrupt does: suspend the raising call (default) or stop the loop and return the interrupts.
    public let interruptMode: InterruptMode
    /// `agent._interrupt_state`.
    private var interruptState = InterruptState()
    /// The `.suspend` half of the interrupt system — one continuation per unanswered interrupt.
    private var gate = InterruptGate()
    /// Interrupts waiting for a human right now (a UI restores its cards from this).
    public var pendingInterrupts: [Interrupt] { gate.pending }
    /// Tool calls waiting for an approval decision right now (a UI restores its cards from this).
    public var pendingApprovals: [ApprovalRequest] {
        gate.pending.compactMap { interrupt in
            guard interrupt.name == Agent.approvalInterruptName, let reason = interrupt.reason else { return nil }
            return ApprovalRequest(interruptReason: reason)
        }.sorted { $0.id < $1.id }
    }
    /// `.stop` mode only: tool calls that raised an interrupt instead of producing a result.
    private var interrupted = InterruptedToolUses()

    /// The tools this model is actually offered: `tools` minus the ones that
    /// merely wrap the active runtime (`Tool.redundantWithRuntime`).
    public var offeredTools: [any Tool] { tools.filter { $0.isOffered(to: model.kind) } }
    /// Names in `tools` that are withheld from this model, with the runtime they duplicate.
    public var withheldTools: [(name: String, runtime: RuntimeKind)] {
        tools.compactMap { t in t.isOffered(to: model.kind) ? nil : (t.name, model.kind) }
    }

    /// - Parameters:
    ///   - conversationManager: default `SlidingWindowConversationManager()` — the only limiter.
    ///   - hooks: `HookProvider`s registered after the manager and the retry strategy.
    ///   - toolExecutor: default `ConcurrentToolExecutor()`.
    ///   - retryStrategy: default `ModelRetryStrategy()` (6 attempts, 4 s → 240 s). Pass `nil` to disable.
    ///   - approvalTimeout: a tool call waiting for `resolve(approval:)` is denied after this (default 120 s).
    /// - interruptMode: `.suspend` (default — the raising call waits inside the agent) or `.stop` (
    ///     the loop returns `stopReason .interrupt` and the caller answers with `resume(_:)`).
    public init(model: any Model,
                tools: [any Tool] = [],
                systemPrompt: String? = nil,
                messages: [Message] = [],
                conversationManager: any ConversationManager = SlidingWindowConversationManager(),
                hooks: [any HookProvider] = [],
                toolExecutor: any ToolExecutor = ConcurrentToolExecutor(),
                retryStrategy: ModelRetryStrategy? = ModelRetryStrategy(),
                approvalTimeout: TimeInterval = 120,
                interruptMode: InterruptMode = .suspend) {
        self.model = model
        self.approvalTimeout = approvalTimeout
        self.interruptMode = interruptMode
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

    /// Edits the running tool applied to the WORKING context, announced (`.historyEdited`) when the tool returns.
    private var pendingHistoryEdits: [HistoryEdit] = []
    /// `manage_messages`: the agent edits its OWN working context (`HistoryEditor`, pure — the active turn is
    /// never touched, orphaned toolUses get synthetic results, the structure is validated first). The
    /// replacement is what the NEXT model call of the same turn reads, because `handleModelExecution` takes
    /// `messages` at request time. The usage baseline is dropped: the next projection re-estimates from shape.
    /// A host's transcript / history is built from events and keeps the user's full record.
    public func editHistory(_ request: HistoryEditor.Request, selfToolUseId: String? = nil) throws -> HistoryEditor.Outcome {
        let specs = offeredTools.map(\.toolSpec)
        let outcome = try HistoryEditor.apply(request, to: messages, selfId: selfToolUseId,
                                              projectedTokens: usageBaseline == nil ? nil : projectedInputTokens(toolSpecs: specs))
        if let edit = outcome.edit {
            messages = outcome.messages
            usageBaseline = nil
            pendingHistoryEdits.append(edit)
        }
        return outcome
    }
    public func reset() {
        messages.removeAll()
        eventLoopMetrics = EventLoopMetrics()
        interruptState.deactivate()
        gate = InterruptGate()
        interrupted = InterruptedToolUses()
        requestState = [:]
    }

    // MARK: interrupts (`interrupt.py`) + human-in-the-loop

    /// The interrupt name an approval request is raised under.
    static let approvalInterruptName = "approval"
    static func approvalInterruptId(_ toolUseId: String) -> String { "tool:\(toolUseId):\(approvalInterruptName)" }

    /// Answer a raised interrupt (`AgentEvent.interruptRaised`). Returns false when nothing
    /// with that id is waiting (already answered, timed out, or cancelled).
    @discardableResult
    public func resolve(interrupt id: String, response: JSONValue) -> Bool {
        interruptState.interrupts[id]?.response = response
        return gate.resolve(id, response)
    }

    /// Answer a suspended tool call (`AgentEvent.approvalRequested`). Returns false when nothing
    /// with that id is waiting (already answered, timed out, or cancelled).
    /// `id` is the `toolUseId`, exactly as in the request.
    @discardableResult
    public func resolve(approval id: String, _ decision: ApprovalDecision) -> Bool {
        resolve(interrupt: Agent.approvalInterruptId(id), response: decision.interruptResponse)
    }

    /// Resume: fold answers into the interrupt state and continue the loop
    /// from the pending tool execution (already-completed tool results are kept).
    public func resume(_ responses: [InterruptResponse]) async throws -> AgentResult {
        try await invoke(.interruptResponses(responses))
    }

    /// Suspend the current call until the interrupt is resolved, the timeout fires, or the task
    /// is cancelled. Awaiting the continuation releases the actor, so the other tools of the
    /// message keep running. `onTimeout` is the response substituted when nobody answers.
    private func suspend(_ interrupt: Interrupt, timeout: TimeInterval?, onTimeout: JSONValue) async -> JSONValue {
        let id = interrupt.id
        if let early = gate.take(interrupt) { return early }
        let timer: Task<Void, Never>? = timeout.map { t in
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, t) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.resolve(interrupt: id, response: onTimeout)
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<JSONValue, Never>) in
                gate.park(id, c)
            }
        } onCancel: {
            Task { [weak self] in await self?.resolve(interrupt: id, response: onTimeout) }
        }
    }

    /// Invoke an interruptible hook event: the agent injects the interrupts it
    /// already knows about, and a callback that raises one either suspends here (`.suspend`) and
    /// the whole chain is re-run with the answer available, or unwinds (`.stop`).
    ///
    /// One interrupt per pass (rather than collecting every callback's interrupts in one go; here the
    /// chain is simply re-entered until no callback raises, which answers them one at a time).
    private func invokeInterruptible<E: InterruptibleEvent>(_ event: E, scope: String,
                                                            timeout: TimeInterval?,
                                                            _ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> E {
        var e = event
        while true {
            e.interruptContext = InterruptContext(scope: scope, known: interruptState.interrupts)
            do {
                return try await hooks.invoke(e)
            } catch let raised as InterruptException {
                interruptState.register([raised.interrupt])
                guard interruptMode == .suspend else { throw raised }
                let answer = await awaitAnswer(raised.interrupt, timeout: timeout, onTimeout: .null, yield)
                interruptState.interrupts[raised.interrupt.id]?.response = answer
            }
        }
    }

    /// `.suspend`: announce the interrupt, park until it is answered, announce the answer.
    private func awaitAnswer(_ interrupt: Interrupt, timeout: TimeInterval?, onTimeout: JSONValue,
                             _ yield: @Sendable @escaping (AgentEvent) -> Void) async -> JSONValue {
        gate.arm(interrupt.id)
        if interrupt.name == Agent.approvalInterruptName, let reason = interrupt.reason,
           let request = ApprovalRequest(interruptReason: reason) {
            yield(.approvalRequested(request))
        } else {
            yield(.interruptRaised(interrupt))
        }
        let answer = await suspend(interrupt, timeout: timeout, onTimeout: onTimeout)
        if interrupt.name == Agent.approvalInterruptName, let decision = ApprovalDecision(interruptResponse: answer) {
            yield(.approvalResolved(id: ApprovalRequest.toolUseId(fromInterruptId: interrupt.id), decision))
        } else {
            yield(.interruptResolved(id: interrupt.id, response: answer))
        }
        return answer
    }

    /// `_stop_for_interrupts`: persist what is needed to resume, then stop the loop.
    private func stopForInterrupts(_ message: Message, _ completed: [ToolResult], _ raised: [Interrupt]) -> AgentResult {
        interruptState.pendingToolExecution = PendingToolExecution(assistantMessage: message,
                                                                   completedToolResults: completed)
        interruptState.activate()
        return AgentResult(stopReason: .interrupt, message: message, metrics: eventLoopMetrics, interrupts: raised)
    }

    // MARK: `__call__` / `invoke_async`

    /// Run to completion with a text prompt.
    public func callAsFunction(_ prompt: String) async throws -> AgentResult { try await invoke(.text(prompt)) }
    /// Run to completion with explicit messages (accepts `Messages` too).
    public func callAsFunction(_ messages: [Message]) async throws -> AgentResult { try await invoke(.messages(messages)) }
    /// Continue from the current history without new input (`agent` with `prompt=None`,
    /// e.g. after `MaxTokensReachedError`).
    public func callAsFunction() async throws -> AgentResult { try await invoke(.continue) }

    /// What a call to the agent carries: a prompt, a full message list, or `continue` to resume.
    public enum Input: Sendable {
        case text(String), messages([Message]), `continue`
        /// Resume-from-interrupt: `agent([{"interruptResponse": …}])`.
        case interruptResponses([InterruptResponse])
    }

    public func invoke(_ input: Input) async throws -> AgentResult {
        var result: AgentResult?
        for try await e in stream(input) { if case .result(let r) = e { result = r } }
        guard let result else { throw EventLoopError(ModelError("event loop ended without a result")) }
        return result
    }

    // MARK: `stream_async`

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

    // MARK: `_run_loop`

    private func runLoop(_ input: Input, _ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> AgentResult {
        let newMessages: [Message]
        switch input {
        case .text(let t): newMessages = [.user(t)]
        case .messages(let m): newMessages = m
        case .continue: newMessages = []
        case .interruptResponses(let responses):
            // `_InterruptState.resume`: the answers go into the interrupt state and the
            // loop picks the pending tool execution back up — no new user turn, no model call.
            try interruptState.resume(responses)
            newMessages = []
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

    // MARK: `_execute_event_loop_cycle` (overflow → reduce → retry)

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
    /// reducing context and retrying the reduced prompt (on
    /// a 4096-token runtime one reduction is enough or nothing will be).
    public static let maxContextReductions = 1

    // MARK: `event_loop_cycle`

    private func eventLoopCycle(_ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> AgentResult {
        eventLoopMetrics.cycleCount += 1
        yield(.startEventLoop(cycle: eventLoopMetrics.cycleCount))

        let stopReason: StopReason
        let message: Message
        if interruptState.activated, let pending = interruptState.pendingToolExecution {
            // Resuming an interrupted tool cycle: replay the stored assistant message
            // (`event_loop_cycle` — "Resume a tool interrupt by replaying its stored message").
            stopReason = .toolUse; message = pending.assistantMessage
        } else if let last = messages.last, last.role == .assistant, last.hasToolUse {
            // A previous run was cut off before its tools ran — resume there (`_has_tool_use_in_latest_message`).
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

    // MARK: `_handle_model_execution` (hooks + retry loop around one stream)

    private func handleModelExecution(_ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> (StopReason, Message) {
        while true {
            try Task.checkCancellation()
            let specs = offeredTools.map(\.toolSpec)
            let contextWindow = await model.contextWindow     // per-runtime: Apple FM 4096, MLX/GGUF their real ctx
            var before = BeforeModelCallEvent(messages: messages, systemPrompt: systemPrompt,
                                              projectedInputTokens: projectedInputTokens(toolSpecs: specs),
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
                            case .textReplace(let s): yield(.textReplace(s))
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
                    // `process_stream` with cancel_signal set → stop_reason "cancelled".
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
                recordUsageBaseline(stop.metrics, for: message)
                return (stopReason, message)
            } catch {
                var after = AfterModelCallEvent(stopResponse: nil, error: error)
                after = try await hooks.invoke(after)
                if let d = retryStrategy?.lastDelay { yield(.throttle(delay: d)) }
                if after.retry { continue }
                if !(error is ContextWindowOverflowError) {      // overflow is recovered one level up, silently (yields ForceStop first)
                    yield(.forceStop((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                }
                throw error
            }
        }
    }

    // MARK: `_handle_tool_execution`

    private func handleToolExecution(_ message: Message, _ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> AgentResult {
        var toolUses = message.toolUses
        /// Results carried over from an interrupted cycle — kept, never re-run (merges
        /// `pending_tool_execution.completed_tool_results` and filters the tool uses that have one).
        var results: [ToolResult] = []
        if interruptState.activated, let pending = interruptState.pendingToolExecution {
            results = pending.completedToolResults
            let done = Set(results.map(\.toolUseId))
            toolUses = toolUses.filter { !done.contains($0.toolUseId) }
        }
        let interrupted = InterruptedToolUses()
        self.interrupted = interrupted

        // Pairs BeforeToolsEvent with AfterToolsEvent in a `finally`. Swift's `defer`
        // cannot `await`, so the pairing is spelled out: every exit from the block below goes
        // through `fireAfterTools`, including the throwing ones.
        var before = BeforeToolsEvent(message: message)
        do {
            before = try await invokeInterruptible(before, scope: "tools:\(message.id.uuidString)",
                                                   timeout: approvalTimeout, yield)
        } catch let raised as InterruptException {
            // `.stop`: a BeforeTools hook interrupted before anything ran.
            _ = try? await fireAfterTools(results, append: false, yield)
            return stopForInterrupts(message, results, [raised.interrupt])
        } catch {
            _ = try? await fireAfterTools(results, append: false, yield)
            throw error
        }

        let cancelMessage: String? = before.cancel.map { $0.isEmpty ? "Tool cancelled by hook" : $0 } ?? (Task.isCancelled ? "Tool execution cancelled" : nil)

        if let cancelMessage {
            let cancelled = toolUses.map { ToolResult.error($0, cancelMessage) }
            cancelled.forEach { yield(.toolResult($0)) }
            results += cancelled
        } else {
            // `validate_and_prepare_tools`: a toolUse the model broke never reaches a tool —
            // it gets an error result and keeps its place in the result list.
            let validation = ToolValidation.validateAndPrepare(toolUses: toolUses, tools: offeredTools)
            validation.results.forEach { yield(.toolResult($0)) }
            results += validation.results
            let executed = await toolExecutor.execute(validation.valid,
                                                      run: { [self] use in await self.runTool(use, yield) },
                                                      emit: { r in if !interrupted.contains(r.toolUseId) { yield(.toolResult(r)) } })
            results += executed.filter { !interrupted.contains($0.toolUseId) }
        }

        let raised = interruptMode == .stop ? interruptState.unanswered : []
        if !raised.isEmpty {
            // AfterTools still fires (finally), then the loop stops with the interrupts.
            _ = try? await fireAfterTools(results, append: false, yield)
            return stopForInterrupts(message, results, raised)
        }

        let after = try await fireAfterTools(results, append: true, yield)
        eventLoopMetrics.toolCallCount += toolUses.count
        // A completed tool cycle starts the next one clean.
        if !Task.isCancelled { interruptState.endToolCycle() } else { interruptState.setPendingToolResults(results) }

        if Task.isCancelled {
            return AgentResult(stopReason: .cancelled, message: message, metrics: eventLoopMetrics)
        }

        // `after_tools_event.end_turn`: a hook ends the turn without calling the model again.
        if let endTurn = after.endTurn {
            let endMessage = Message(role: .assistant, content: endTurn.content)
            try await appendMessage(endMessage)
            yield(.modelMessage(endMessage))
            return AgentResult(stopReason: .endTurn, message: endMessage, metrics: eventLoopMetrics)
        }
        // `invocation_state["request_state"]["stop_event_loop"]`: stop with this cycle's stop reason.
        requestState = after.requestState
        if requestState["stopEventLoop"] == .bool(true) || requestState["stop_event_loop"] == .bool(true) {
            return AgentResult(stopReason: .toolUse, message: message, metrics: eventLoopMetrics)
        }
        return try await recurseEventLoop(yield)
    }

    /// `finally` block: build the toolResult message, run the AfterToolsEvent hooks, and
    /// (unless the loop is stopping for an interrupt) append it + announce it.
    @discardableResult
    private func fireAfterTools(_ results: [ToolResult], append: Bool,
                                _ yield: @Sendable @escaping (AgentEvent) -> Void) async throws -> AfterToolsEvent {
        var after = AfterToolsEvent(message: .toolResults(results), requestState: requestState)
        after = try await hooks.invoke(after)
        if append {
            try await appendMessage(after.message)
            yield(.toolResultMessage(after.message))
        }
        return after
    }

    /// `ToolExecutor._stream`: BeforeToolCall → run → AfterToolCall, never throws (errors become error results).
    /// A hook or the tool itself may raise an interrupt here: in `.suspend` it parks this one call
    /// (the others keep running), in `.stop` it marks the id and the cycle stops without a result.
    private func runTool(_ use: ToolUse, _ yield: @Sendable @escaping (AgentEvent) -> Void) async -> ToolResult {
        let t0 = Date()
        let scope = "tool:\(use.toolUseId)"
        let selected = offeredTools.first { $0.name == use.name }
        var approval = selected?.requiresApproval(for: use.input)
        approval?.id = use.toolUseId; approval?.toolName = use.name
        if approval?.input.isEmpty == true { approval?.input = use.input }
        var before = BeforeToolCallEvent(toolUse: use, selectedTool: selected, approval: approval)
        do {
            before = try await invokeInterruptible(before, scope: scope, timeout: approvalTimeout, yield)
        } catch let raised as InterruptException {
            interrupted.insert(use.toolUseId)      // `.stop`: no result for this tool use
            return .error(use, "interrupted: \(raised.interrupt.name)")
        } catch {
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
            // Human-in-the-loop, as one interrupt: suspend this call (and only this call) until a decision arrives.
            request.id = toolUse.toolUseId; request.toolName = toolUse.name
            if request.input.isEmpty { request.input = toolUse.input }
            let interrupt = Interrupt(id: Agent.approvalInterruptId(toolUse.toolUseId),
                                      name: Agent.approvalInterruptName,
                                      reason: request.interruptReason)
            interruptState.register([interrupt])
            if interruptMode == .stop, interruptState.interrupts[interrupt.id]?.response == nil {
                yield(.approvalRequested(request))
                interrupted.insert(toolUse.toolUseId)
                return .error(toolUse, "awaiting approval")
            }
            let answer: JSONValue
            if let existing = interruptState.interrupts[interrupt.id]?.response {
                answer = existing                                  // resumed: the human already answered
            } else {
                answer = await awaitAnswer(interrupt, timeout: approvalTimeout,
                                           onTimeout: ApprovalDecision.deny(reason: "no answer within \(Int(approvalTimeout)) s").interruptResponse,
                                           yield)
                interruptState.interrupts[interrupt.id]?.response = answer
            }
            switch ApprovalDecision(interruptResponse: answer) ?? .deny(reason: "unreadable decision") {
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
            // The tool may raise an interrupt of its own (`InterruptScope.interrupt`): in `.suspend`
            // it is answered and the tool runs again with the answer in its context.
            while true {
                let context = InterruptContext(scope: scope, known: interruptState.interrupts)
                do {
                    let toolContext = ToolContext(agent: self, toolUseId: toolUse.toolUseId)
                    let out = try await InterruptScope.$context.withValue(context) {
                        try await ToolContext.$current.withValue(toolContext) {
                            try await tool.call(toolUse.input, images: Self.visibleImages(messages))
                        }
                    }
                    flushHistoryEdits(yield)
                    result = ToolResult(toolUseId: toolUse.toolUseId, name: toolUse.name, status: .success, content: out.text,
                                        durationMs: Date().timeIntervalSince(t0) * 1000, images: out.images)
                    break
                } catch let raised as InterruptException {
                    interruptState.register([raised.interrupt])
                    guard interruptMode == .suspend else {
                        interrupted.insert(toolUse.toolUseId)
                        return .error(toolUse, "interrupted: \(raised.interrupt.name)")
                    }
                    let answer = await awaitAnswer(raised.interrupt, timeout: approvalTimeout, onTimeout: .null, yield)
                    interruptState.interrupts[raised.interrupt.id]?.response = answer
                } catch {
                    flushHistoryEdits(yield)
                    thrown = error
                    result = ToolResult(toolUseId: toolUse.toolUseId, name: toolUse.name, status: .error,
                                        content: "Error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")",
                                        durationMs: Date().timeIntervalSince(t0) * 1000)
                    break
                }
            }
        } else {
            result = .error(toolUse, "Unknown tool: \(toolUse.name). Available tools: \(offeredTools.map(\.name).sorted().joined(separator: ", "))",
                            durationMs: Date().timeIntervalSince(t0) * 1000)
        }
        var after = AfterToolCallEvent(toolUse: toolUse, selectedTool: before.selectedTool, result: result, error: thrown)
        after = (try? await hooks.invoke(after)) ?? after
        return after.result
    }

    // MARK: `_estimate_input_tokens` (usage baseline, not a re-count)

    /// Reads the last assistant message's `usage` as a known baseline and estimates only
    /// the messages added after it; a cold start (or a baseline the sliding window has trimmed
    /// away) falls back to estimating everything, system prompt and tool specs included.
    ///
    /// loopl's `Message` carries no metadata, so the baseline lives here, keyed by the id of the
    /// assistant message the runtime reported it for. Both halves are ESTIMATES in the sense that
    /// matters: the baseline is the runtime's own count (real for MLX/llama.cpp, `estimated` for
    /// Apple FM), the tail is `TokenEstimator`'s chars/4 — never a tokenizer.
    func projectedInputTokens(toolSpecs specs: [ToolSpec]) -> Int {
        guard let baseline = usageBaseline,
              let index = messages.lastIndex(where: { $0.id == baseline.messageID }) else {
            return TokenEstimator.estimate(messages: messages, systemPrompt: systemPrompt, toolSpecs: specs)
        }
        let newMessages = messages[(index + 1)...]
        guard !newMessages.isEmpty else { return baseline.tokens }
        return baseline.tokens + newMessages.reduce(0) { $0 + TokenEstimator.estimate($1) }
    }

    /// Fold a model call's measured usage in as the new baseline (the assistant
    /// message's `metadata.usage`). `promptTokens + generatedTokens` is what the next prompt
    /// will carry, so that is the baseline, exactly as in `_estimate_input_tokens`.
    private func recordUsageBaseline(_ metrics: Metrics, for message: Message) {
        let tokens = metrics.promptTokens + metrics.generatedTokens
        guard tokens > 0 else { return }       // a runtime that reports nothing cannot be a baseline
        usageBaseline = (message.id, tokens)
        eventLoopMetrics.usageBaselineTokens = tokens
    }

    /// Announce the edits a tool applied during its call (`AgentEvent.historyEdited`), in order.
    private func flushHistoryEdits(_ yield: @Sendable @escaping (AgentEvent) -> Void) {
        guard !pendingHistoryEdits.isEmpty else { return }
        let edits = pendingHistoryEdits
        pendingHistoryEdits.removeAll()
        edits.forEach { yield(.historyEdited($0)) }
    }

    // MARK: `_append_messages` (+ MessageAddedEvent)

    private func appendMessage(_ m: Message) async throws {
        messages.append(m)
        try await hooks.invoke(MessageAddedEvent(message: m))
    }
}


extension Agent {
    /// The pictures an image-consuming tool may look at this turn: the ones attached to the latest user message, followed
    /// by every picture a tool returned since then (`ToolResult.images`), most recent last — so `photos_recent` →
    /// `describe_image {image_index: 0}` describes the newest photo. Measured 2026-10-06 (ContactsPhotosMeasurement):
    /// before this, the model called describe_image after photos_recent 3/3 and got "no image attached" 3/3.
    static func visibleImages(_ messages: [Message]) -> [ImageBlock] {
        // Tool results travel as `role: .user` turns too — so "the latest user message" used to be the tool-result turn,
        // and a picture the user attached vanished for every tool after the first call of the turn.
        guard let userIdx = messages.lastIndex(where: { $0.role == .user && !$0.hasToolResult }) else { return [] }
        var images = messages[userIdx].images
        for m in messages[(userIdx + 1)...] { for r in m.toolResults { images += r.images } }
        return images
    }
}
