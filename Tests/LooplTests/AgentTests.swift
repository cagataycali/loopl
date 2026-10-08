import XCTest
import Loopl

/// Strands event-loop behaviours, driven by the test-only `FakeModel`.
final class AgentTests: XCTestCase {
    func use(_ name: String, _ args: [String: JSONValue] = [:], id: String = ToolUse.makeId()) -> ToolUse {
        ToolUse(toolUseId: id, name: name, input: args)
    }
    func markup(_ name: String, _ args: [String: JSONValue] = [:]) -> String {
        "<tool_call>{\"name\": \"\(name)\", \"arguments\": \(JSONValue.object(args).compact)}</tool_call>"
    }
    /// A tool that records call order and can be slowed per call.
    final class Recorder: @unchecked Sendable {
        var started: [String] = []; var finished: [String] = []
        let lock = NSLock()
        func start(_ s: String) { lock.lock(); started.append(s); lock.unlock() }
        func finish(_ s: String) { lock.lock(); finished.append(s); lock.unlock() }
    }
    func sleepy(_ rec: Recorder) -> ClosureTool {
        ClosureTool(name: "sleepy", description: "sleeps", parameters: ToolSchema.object(["ms": ToolSchema.number("ms"), "tag": ToolSchema.string("tag")])) { args in
            let tag = args["tag"]?.stringValue ?? "?"
            rec.start(tag)
            try await Task.sleep(nanoseconds: UInt64((args["ms"]?.doubleValue ?? 0) * 1_000_000))
            rec.finish(tag)
            return "slept \(tag)"
        }
    }

    // MARK: event loop

    func testToolUseThenEndTurn_nativeBlocks() async throws {
        let model = FakeModel(turns: [.toolUse(text: "Let me compute.", [use("calculator", ["expression": "23*47"], id: "t1")]), .text("23 × 47 is 1081.")])
        let agent = Agent(model: model, tools: [CalculatorTool()], systemPrompt: "s", retryStrategy: nil)
        var events: [AgentEvent] = []
        for try await e in agent.stream("23*47?") { events.append(e) }

        let results = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }
        XCTAssertEqual(results.map(\.content), ["23*47 = 1081"])
        XCTAssertEqual(results[0].toolUseId, "t1"); XCTAssertFalse(results[0].isError)
        guard case .result(let r)? = events.last else { return XCTFail("last event must be .result") }
        XCTAssertEqual(r.stopReason, .endTurn); XCTAssertEqual(r.text, "23 × 47 is 1081."); XCTAssertEqual(r.metrics.cycleCount, 2); XCTAssertEqual(r.metrics.toolCallCount, 1)

        // Second model call sees: user, assistant(toolUse), user(toolResult); system prompt travels separately.
        let prompts = await model.seenPrompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts[1].map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(prompts[1][1].toolUses.first?.name, "calculator")
        XCTAssertEqual(prompts[1][2].toolResults.first?.toolUseId, "t1")
        let systems = await model.seenSystemPrompts
        XCTAssertEqual(systems, ["s", "s"])
        let specs = await model.seenToolSpecs
        XCTAssertEqual(specs[0].map(\.name), ["calculator"])
        // History (Strands agent.messages): 4 messages, no system message inside.
        let history = await agent.messages
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history.last?.text, "23 × 47 is 1081.")
        // Streaming order: startEventLoop(1) … modelMessage … toolStarted … toolResult … toolResultMessage … startEventLoop(2) … result
        let kinds = events.map { e -> String in
            switch e {
            case .initEventLoop: "init"
            case .startEventLoop(let c): "start\(c)"
            case .modelMessage: "msg"
            case .toolStarted: "toolStart"
            case .toolResult: "toolResult"
            case .toolResultMessage: "toolMsg"
            case .result: "result"
            default: ""
            }
        }.filter { !$0.isEmpty }
        XCTAssertEqual(kinds, ["init", "start1", "msg", "toolStart", "toolResult", "toolMsg", "start2", "msg", "result"])
    }

    func testMarkupToolCallIsResolvedProviderSide() async throws {
        // Text-only model: the gate turns <tool_call> into a toolUse block; the visible text never shows markup.
        let model = FakeModel(scripts: ["Checking. " + markup("calculator", ["expression": "2+2"]), "4"])
        let agent = Agent(model: model, tools: [CalculatorTool()], retryStrategy: nil)
        var text = ""; var toolUses: [ToolUse] = []
        for try await e in agent.stream("2+2?") {
            if case .text(let t) = e { text += t }
            if case .modelMessage(let m) = e { toolUses += m.toolUses }
        }
        XCTAssertEqual(toolUses.map(\.name), ["calculator"])
        XCTAssertEqual(toolUses[0].input["expression"], .string("2+2"))
        XCTAssertFalse(text.contains("<tool_call>"), "markup leaked into text: \(text)")
        XCTAssertTrue(text.hasPrefix("Checking."))
        XCTAssertTrue(text.hasSuffix("4"))
    }

    func testCallAsFunctionReturnsResult() async throws {
        let model = FakeModel(turns: [.toolUse([use("calculator", ["expression": "2+2"])]), .text("4")])
        let r = try await Agent(model: model, tools: [CalculatorTool()], retryStrategy: nil)("2+2?")
        XCTAssertEqual(r.text, "4"); XCTAssertEqual(r.stopReason, .endTurn); XCTAssertEqual(r.metrics.cycleCount, 2)
    }

    func testUnknownToolBecomesErrorResultAndLoopContinues() async throws {
        let model = FakeModel(turns: [.toolUse([use("nope")]), .text("ok")])
        var errors: [ToolResult] = []
        for try await e in Agent(model: model, tools: [CalculatorTool()], retryStrategy: nil).stream("x") {
            if case .toolResult(let r) = e { errors.append(r) }
        }
        XCTAssertEqual(errors.count, 1); XCTAssertTrue(errors[0].isError); XCTAssertTrue(errors[0].content.contains("Unknown tool: nope"))
    }

    func testToolErrorBecomesErrorResult() async throws {
        let boom = ClosureTool(name: "boom", description: "") { _ in throw ToolError("kaboom") }
        let model = FakeModel(turns: [.toolUse([use("boom")]), .text("handled")])
        let r = try await Agent(model: model, tools: [boom], retryStrategy: nil)("x")
        XCTAssertEqual(r.text, "handled")
        let history = await Agent(model: model, tools: [boom]).messages   // fresh agent → empty
        XCTAssertTrue(history.isEmpty)
    }

    func testTwentyFiveDeepChainHasNoCap() async throws {
        var turns: [FakeModel.Turn] = []
        for i in 1...25 { turns.append(.toolUse([use("calculator", ["expression": .string("\(i)+1")])])) }
        turns.append(.text("done after twenty-five"))
        let model = FakeModel(turns: turns, contextLength: 1_000_000)
        let r = try await Agent(model: model, tools: [CalculatorTool()], conversationManager: NullConversationManager(), retryStrategy: nil)("count")
        XCTAssertEqual(r.metrics.cycleCount, 26); XCTAssertEqual(r.metrics.toolCallCount, 25); XCTAssertEqual(r.text, "done after twenty-five")
        let history = await model.seenPrompts.last?.count
        XCTAssertEqual(history, 1 + 25 * 2)
    }

    // MARK: tool executors

    func testConcurrentExecutorRunsToolsTogetherAndKeepsMessageOrder() async throws {
        let rec = Recorder()
        let uses = [use("sleepy", ["ms": 120, "tag": "slow"], id: "a"), use("sleepy", ["ms": 10, "tag": "fast"], id: "b")]
        let model = FakeModel(turns: [.toolUse(uses), .text("ok")])
        let agent = Agent(model: model, tools: [sleepy(rec)], retryStrategy: nil)
        var emitted: [String] = []
        for try await e in agent.stream("go") { if case .toolResult(let r) = e { emitted.append(r.toolUseId) } }
        XCTAssertEqual(rec.finished, ["fast", "slow"], "both ran at once: the fast one finished first")
        XCTAssertEqual(emitted, ["b", "a"], "results are emitted as they complete")
        let msgs = await agent.messages
        XCTAssertEqual(msgs[2].toolResults.map(\.toolUseId), ["a", "b"], "the toolResult message keeps toolUse order")
    }

    func testSequentialExecutorRunsInOrder() async throws {
        let rec = Recorder()
        let uses = [use("sleepy", ["ms": 60, "tag": "first"]), use("sleepy", ["ms": 1, "tag": "second"])]
        let model = FakeModel(turns: [.toolUse(uses), .text("ok")])
        _ = try await Agent(model: model, tools: [sleepy(rec)], toolExecutor: SequentialToolExecutor(), retryStrategy: nil)("go")
        XCTAssertEqual(rec.started, ["first", "second"]); XCTAssertEqual(rec.finished, ["first", "second"])
    }

    // MARK: max_tokens recovery

    func testMaxTokensRecoversMessageAndThrows() async throws {
        let model = FakeModel(turns: [.maxTokens(text: "I will", [use("calculator", ["expression": "1+1"], id: "cut")])])
        let agent = Agent(model: model, tools: [CalculatorTool()], retryStrategy: nil)
        do {
            _ = try await agent("x")
            XCTFail("expected MaxTokensReachedError")
        } catch let e as MaxTokensReachedError {
            XCTAssertFalse(e.message.hasToolUse, "recovered message has no toolUse blocks")
            XCTAssertTrue(e.message.text.contains("calculator's tool use was incomplete"))
        }
        let history = await agent.messages
        XCTAssertEqual(history.count, 2, "the recovered partial message is in history")
        XCTAssertEqual(history[1].role, .assistant)
        XCTAssertFalse(history[1].hasToolUse)
        // Strands: the caller may continue; the next call carries on from history.
        await model.append(.text("continuing"))
        let r = try await agent()
        XCTAssertEqual(r.text, "continuing")
        let prompts = await model.seenPrompts
        XCTAssertEqual(prompts.last?.count, 2)
    }

    func testRecoverFunctionReplacesOnlyToolUses() {
        let m = Message(role: .assistant, content: [.text("a"), .toolUse(use("x")), .reasoning("r")])
        let out = recoverMessageOnMaxTokensReached(m)
        XCTAssertEqual(out.content.count, 3)
        XCTAssertEqual(out.content[0], .text("a"))
        XCTAssertEqual(out.content[1].text, "The selected tool x's tool use was incomplete due to maximum token limits being reached.")
        XCTAssertEqual(out.content[2], .reasoning("r"))
    }

    // MARK: retry

    func testRetryThenSuccessWithBackoff() async throws {
        let model = FakeModel(turns: [.failure(ModelThrottledError("gpu busy")), .failure(ModelThrottledError("gpu busy")), .text("ok")])
        let strategy = ModelRetryStrategy(maxAttempts: 6, initialDelay: 0.01, maxDelay: 1)
        let agent = Agent(model: model, retryStrategy: strategy)
        var throttles: [TimeInterval] = []
        var result: AgentResult?
        for try await e in agent.stream("x") {
            if case .throttle(let d) = e { throttles.append(d) }
            if case .result(let r) = e { result = r }
        }
        XCTAssertEqual(result?.text, "ok")
        XCTAssertEqual(throttles.count, 2)
        XCTAssertEqual(throttles[0], 0.01, accuracy: 1e-9); XCTAssertEqual(throttles[1], 0.02, accuracy: 1e-9)
        do { let v = await model.seenPrompts.count; XCTAssertEqual(v, 3) }
        do { let v = await agent.messages.count; XCTAssertEqual(v, 2, "failed attempts leave nothing in history") }
    }

    func testRetryGivesUpAfterMaxAttempts() async throws {
        let model = FakeModel(turns: Array(repeating: .failure(ModelThrottledError("busy")), count: 5))
        let agent = Agent(model: model, retryStrategy: ModelRetryStrategy(maxAttempts: 3, initialDelay: 0.001, maxDelay: 0.01))
        var forceStops = 0
        do {
            for try await e in agent.stream("x") { if case .forceStop = e { forceStops += 1 } }
            XCTFail("expected throw")
        } catch is ModelThrottledError {}
        do { let v = await model.seenPrompts.count; XCTAssertEqual(v, 3) }
        XCTAssertEqual(forceStops, 1)
    }

    func testNonRetryableErrorPropagatesImmediately() async throws {
        let model = FakeModel(turns: [.failure(ModelError("bad weights")), .text("never")])
        do { _ = try await Agent(model: model)("x"); XCTFail() } catch let e as ModelError { XCTAssertEqual(e.message, "bad weights") }
        do { let v = await model.seenPrompts.count; XCTAssertEqual(v, 1) }
    }

    // MARK: conversation manager

    func testSlidingWindowTrimKeepsToolPairs() throws {
        var msgs: [Message] = [.user("q0")]
        for i in 0..<10 {
            msgs.append(.assistant(text: "", toolUses: [use("t", ["i": .number(Double(i))], id: "u\(i)")]))
            msgs.append(.toolResults([ToolResult(toolUseId: "u\(i)", name: "t", content: "r\(i)")]))
        }
        msgs.append(.assistant("final"))                               // 22 messages
        let mgr = SlidingWindowConversationManager(windowSize: 6)
        mgr.applyManagement(&msgs)
        XCTAssertLessThanOrEqual(msgs.count, 7)
        // Every toolResult still has its toolUse in the message right before it.
        for (i, m) in msgs.enumerated() where m.hasToolResult {
            XCTAssertGreaterThan(i, 0)
            XCTAssertEqual(msgs[i - 1].toolUses.map(\.toolUseId), m.toolResults.map(\.toolUseId), "orphaned toolResult at \(i)")
        }
        // First kept message is a valid start: plain user, or assistant(toolUse) followed by its result (Strands fallback).
        let first = msgs[0]
        XCTAssertTrue((first.role == .user && !first.hasToolResult) || (first.hasToolUse && msgs[1].hasToolResult))
        XCTAssertEqual(mgr.removedMessageCount, 22 - msgs.count)
    }

    func testSlidingWindowOverflowTruncatesBigToolResultsFirst() throws {
        let big = String(repeating: "x", count: 5000)
        var msgs: [Message] = [.user("q"), .assistant(text: "", toolUses: [use("t", id: "u")]), .toolResults([ToolResult(toolUseId: "u", name: "t", content: big)]), .user("next")]
        let mgr = SlidingWindowConversationManager(windowSize: 40)
        try mgr.reduceContext(&msgs, error: ContextWindowOverflowError())
        XCTAssertEqual(msgs.count, 4, "first pass truncates, does not drop")
        let r = msgs[2].toolResults[0].content
        XCTAssertTrue(r.contains("[truncated: 4600 chars removed]")); XCTAssertTrue(r.hasPrefix(String(repeating: "x", count: 200)))
        // Second overflow: nothing left to truncate → trim to the next plain user message.
        try mgr.reduceContext(&msgs, error: ContextWindowOverflowError())
        XCTAssertEqual(msgs.map(\.text), ["next"])
        // Third: cannot reduce further → rethrows as overflow.
        XCTAssertThrowsError(try mgr.reduceContext(&msgs, error: ContextWindowOverflowError())) { XCTAssertTrue($0 is ContextWindowOverflowError) }
    }

    func testAgentRecoversFromContextOverflowByTrimming() async throws {
        // Window of 300 estimated tokens; a long tool chain would overflow → sliding window trims, loop continues.
        var turns: [FakeModel.Turn] = []
        for i in 0..<12 { turns.append(.toolUse([use("echo", ["s": .string(String(repeating: "y", count: 200) + "\(i)")])])) }
        turns.append(.text("done"))
        let echo = ClosureTool(name: "echo", description: "", parameters: ToolSchema.object(["s": ToolSchema.string("")])) { $0["s"]?.stringValue ?? "" }
        let model = FakeModel(turns: turns, contextLength: 400)
        let agent = Agent(model: model, tools: [echo], conversationManager: SlidingWindowConversationManager(windowSize: 40), retryStrategy: nil)
        let r = try await agent("go")
        XCTAssertEqual(r.text, "done"); XCTAssertEqual(r.metrics.cycleCount, 13)
        let longest = await model.seenPrompts.map { TokenEstimator.estimate(messages: $0, systemPrompt: nil, toolSpecs: []) }.max() ?? 0
        XCTAssertLessThan(longest, 400, "every prompt the model saw fit the window")
    }

    func testNullConversationManagerRethrowsOverflow() async throws {
        let model = FakeModel(turns: [.text("x")], contextLength: 8)   // user prompt alone ≥ 8 est. tokens
        do { _ = try await Agent(model: model, conversationManager: NullConversationManager(), retryStrategy: nil)("a fairly long prompt that will not fit the tiny window at all"); XCTFail() }
        catch is ContextWindowOverflowError {}
    }

    // MARK: hooks

    final class Probe: HookProvider, @unchecked Sendable {
        var log: [String] = []; let lock = NSLock()
        func add(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
        func registerHooks(_ r: HookRegistry) {
            r.addCallback(BeforeInvocationEvent.self) { [self] _ in add("BeforeInvocation") }
            r.addCallback(AfterInvocationEvent.self) { [self] _ in add("AfterInvocation") }
            r.addCallback(BeforeModelCallEvent.self) { [self] _ in add("BeforeModelCall") }
            r.addCallback(AfterModelCallEvent.self) { [self] e in add("AfterModelCall:\(e.stopResponse?.stopReason.rawValue ?? "error")") }
            r.addCallback(BeforeToolsEvent.self) { [self] _ in add("BeforeTools") }
            r.addCallback(AfterToolsEvent.self) { [self] _ in add("AfterTools") }
            r.addCallback(BeforeToolCallEvent.self) { [self] e in add("BeforeToolCall:\(e.toolUse.name)") }
            r.addCallback(AfterToolCallEvent.self) { [self] e in add("AfterToolCall:\(e.result.status.rawValue)") }
            r.addCallback(MessageAddedEvent.self) { [self] e in add("MessageAdded:\(e.message.role.rawValue)") }
        }
    }

    func testHookOrder() async throws {
        let probe = Probe()
        let model = FakeModel(turns: [.toolUse([use("calculator", ["expression": "1+1"])]), .text("2")])
        _ = try await Agent(model: model, tools: [CalculatorTool()], hooks: [probe], retryStrategy: nil)("1+1")
        XCTAssertEqual(probe.log, [
            "BeforeInvocation", "MessageAdded:user",
            "BeforeModelCall", "AfterModelCall:tool_use", "MessageAdded:assistant",
            "BeforeTools", "BeforeToolCall:calculator", "AfterToolCall:success", "AfterTools", "MessageAdded:user",
            "BeforeModelCall", "AfterModelCall:end_turn", "MessageAdded:assistant",
            "AfterInvocation",
        ])
    }

    func testAfterCallbacksRunInReverseOrder() async throws {
        let log = Recorder()
        let a = ClosureHooks { r in
            r.addCallback(AfterModelCallEvent.self) { _ in log.start("A") }
            r.addCallback(BeforeModelCallEvent.self) { _ in log.finish("A") }
        }
        let b = ClosureHooks { r in
            r.addCallback(AfterModelCallEvent.self) { _ in log.start("B") }
            r.addCallback(BeforeModelCallEvent.self) { _ in log.finish("B") }
        }
        _ = try await Agent(model: FakeModel(turns: [.text("x")]), hooks: [a, b], retryStrategy: nil)("x")
        XCTAssertEqual(log.finished, ["A", "B"], "Before… in registration order")
        XCTAssertEqual(log.started, ["B", "A"], "After… reversed")
    }

    func testBeforeToolCallCanCancelAndAfterToolCallCanRewrite() async throws {
        let hooks = ClosureHooks { r in
            r.addCallback(BeforeToolCallEvent.self) { e in if e.toolUse.name == "boom" { e.cancelTool = "not allowed" } }
            r.addCallback(AfterToolCallEvent.self) { e in if e.toolUse.name == "calculator" { e.result.content = "rewritten" } }
        }
        let boom = ClosureTool(name: "boom", description: "") { _ in "should not run" }
        let model = FakeModel(turns: [.toolUse([use("boom", id: "b"), use("calculator", ["expression": "1+1"], id: "c")]), .text("ok")])
        let agent = Agent(model: model, tools: [boom, CalculatorTool()], hooks: [hooks], retryStrategy: nil)
        _ = try await agent("x")
        let results = await agent.messages[2].toolResults
        XCTAssertEqual(results.map(\.toolUseId), ["b", "c"])
        XCTAssertTrue(results[0].isError); XCTAssertEqual(results[0].content, "not allowed")
        XCTAssertEqual(results[1].content, "rewritten")
    }

    func testBeforeInvocationCancelShortCircuits() async throws {
        let hooks = ClosureHooks { r in r.addCallback(BeforeInvocationEvent.self) { e in e.cancel = "nope" } }
        let model = FakeModel(turns: [.text("never")])
        let r = try await Agent(model: model, hooks: [hooks], retryStrategy: nil)("x")
        XCTAssertEqual(r.text, "nope"); XCTAssertEqual(r.stopReason, .endTurn)
        do { let v = await model.seenPrompts.count; XCTAssertEqual(v, 0) }
    }

    // MARK: cancellation

    func testCancellationMidStreamEndsWithCancelledResult() async throws {
        let model = FakeModel(turns: [.hang(after: 3)])
        let agent = Agent(model: model, retryStrategy: nil)
        let task = Task { () -> (Int, AgentResult?) in
            var seen = 0
            var result: AgentResult?
            for try await e in agent.stream("x") {
                if case .text = e { seen += 1 }
                if case .result(let r) = e { result = r }
            }
            return (seen, result)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let outcome = try? await task.value
        // Either the stream was torn down (no result) or the loop reported .cancelled — never a hang.
        if let (seen, result) = outcome { XCTAssertEqual(seen, 3); if let result { XCTAssertEqual(result.stopReason, .cancelled) } }
        try await Task.sleep(nanoseconds: 100_000_000)
        let history = await agent.messages
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[1].role, .assistant)
        XCTAssertTrue(history[1].text.hasPrefix("w0 w1 w2") || history[1].text == "Cancelled by user")
    }

    func testCancellationDuringToolsCancelsRemainingAndDoesNotRecurse() async throws {
        let rec = Recorder()
        let model = FakeModel(turns: [.toolUse([use("sleepy", ["ms": 400, "tag": "t"])]), .text("never")])
        let agent = Agent(model: model, tools: [sleepy(rec)], retryStrategy: nil)
        let task = Task { for try await _ in agent.stream("x") {} }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = try? await task.value
        do { let v = await model.seenPrompts.count; XCTAssertEqual(v, 1, "no recursion after cancellation") }
    }

    // MARK: stream assembler

    func testAssemblerOverridesEndTurnWhenToolUsePresent() {
        var a = StreamAssembler()
        for e in [StreamEvent.messageStart(role: .assistant), .contentBlockStart(.toolUse(toolUseId: "1", name: "f")),
                  .contentBlockDelta(.toolUse(input: "{\"a\":")), .contentBlockDelta(.toolUse(input: "1}")), .contentBlockStop, .messageStop(.endTurn)] { _ = a.feed(e) }
        let stop = a.finish()
        XCTAssertEqual(stop.stopReason, .toolUse)
        XCTAssertEqual(stop.message.toolUses.first?.input["a"], .number(1))
    }

    func testAssemblerSkipsIncompleteToolUseAndDefaultsBadJSON() {
        var a = StreamAssembler()
        for e in [StreamEvent.contentBlockStart(.toolUse(toolUseId: "", name: "f")), .contentBlockDelta(.toolUse(input: "{}")), .contentBlockStop,
                  .contentBlockStart(.toolUse(toolUseId: "2", name: "g")), .contentBlockDelta(.toolUse(input: "not json")), .contentBlockStop,
                  .contentBlockStart(.text), .contentBlockDelta(.text("hi")), .contentBlockStop, .messageStop(.toolUse)] { _ = a.feed(e) }
        let stop = a.finish()
        XCTAssertEqual(stop.message.toolUses.map(\.toolUseId), ["2"])
        XCTAssertEqual(stop.message.toolUses[0].input, [:])
        XCTAssertEqual(stop.message.text, "hi")
    }
}

/// Inline hook provider for tests.
struct ClosureHooks: HookProvider {
    let body: @Sendable (HookRegistry) -> Void
    init(_ body: @Sendable @escaping (HookRegistry) -> Void) { self.body = body }
    func registerHooks(_ registry: HookRegistry) { body(registry) }
}

extension FakeModel {
    func append(_ turn: Turn) { turns.append(turn) }
}
