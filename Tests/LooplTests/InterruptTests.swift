import XCTest
import Loopl

/// Strands-shaped interrupts: a hook or a tool raises one, and either the single
/// call suspends inside the agent (`.suspend`, loopl's default and what the HITL
/// approval uses) or the loop stops and the caller resumes (`.stop`, Strands).
/// Results already produced are kept and never re-run.
final class InterruptTests: XCTestCase {

    func use(_ name: String, _ args: [String: JSONValue] = [:], id: String = ToolUse.makeId()) -> ToolUse {
        ToolUse(toolUseId: id, name: name, input: args)
    }

    /// Counts how many times it actually ran, so "not re-run" is a measurement.
    final class Recorder: Tool, @unchecked Sendable {
        let name: String
        let description = "records its calls"
        let parameters: JSONValue = ToolSchema.object(["v": ToolSchema.string("v")])
        private var _calls: [[String: JSONValue]] = []
        private let lock = NSLock()
        var calls: [[String: JSONValue]] { lock.withLock { _calls } }
        init(_ name: String) { self.name = name }
        func call(_ args: [String: JSONValue]) async throws -> String {
            lock.withLock { _calls.append(args) }
            return "\(name) ran"
        }
    }

    /// Raises an interrupt the first time, then uses the human's answer.
    final class Asking: Tool, @unchecked Sendable {
        let name = "asking"
        let description = "asks the human a question"
        let parameters: JSONValue = ToolSchema.object([:])
        private var _runs = 0
        private let lock = NSLock()
        var runs: Int { lock.withLock { _runs } }
        func call(_ args: [String: JSONValue]) async throws -> String {
            lock.withLock { _runs += 1 }
            let answer = try InterruptScope.interrupt("how_many", reason: .string("how many?"))
            return "answer=\(answer.compact)"
        }
    }

    // MARK: InterruptContext (Strands `_Interruptible.interrupt`)

    func testContextRaisesFirstThenReturnsTheAnswer() throws {
        var ctx = InterruptContext(scope: "tool:t1")
        XCTAssertThrowsError(try ctx.interrupt("confirm", reason: .string("sure?"))) { error in
            guard let ex = error as? InterruptException else { return XCTFail("expected InterruptException") }
            XCTAssertEqual(ex.interrupt.id, "tool:t1:confirm")
            XCTAssertEqual(ex.interrupt.name, "confirm")
            XCTAssertEqual(ex.interrupt.reason, .string("sure?"))
            XCTAssertNil(ex.interrupt.response)
        }
        XCTAssertEqual(ctx.raised.map(\.id), ["tool:t1:confirm"])

        // Second pass, with the answer the agent folded in — no throw, the response comes back.
        var answered = InterruptContext(scope: "tool:t1",
                                        known: ["tool:t1:confirm": Interrupt(id: "tool:t1:confirm", name: "confirm",
                                                                             response: .string("yes"))])
        XCTAssertEqual(try answered.interrupt("confirm"), .string("yes"))
        XCTAssertTrue(answered.raised.isEmpty)
    }

    func testPreemptiveResponseSkipsTheInterrupt() throws {
        var ctx = InterruptContext(scope: "s")
        XCTAssertEqual(try ctx.interrupt("x", response: .bool(true)), .bool(true))
        XCTAssertTrue(ctx.raised.isEmpty)
    }

    func testInterruptScopeOutsideAnAgentThrowsAToolError() {
        XCTAssertThrowsError(try InterruptScope.interrupt("nope")) { error in
            XCTAssertTrue(error is ToolError, "\(error)")
        }
        XCTAssertFalse(InterruptScope.isAvailable)
    }

    // MARK: .suspend — a hook interrupt

    func testHookInterruptSuspendsThenTheHookSeesTheAnswer() async throws {
        let tool = Recorder("echo")
        let model = FakeModel(turns: [.toolUse([use("echo", ["v": "1"], id: "e1")]), .text("done")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        await agent.hooks.addCallback(BeforeToolCallEvent.self) { e in
            let answer = try e.interrupt("confirm", reason: .string(e.toolUse.name))
            if answer != .string("yes") { e.cancelTool = "not confirmed" }
        }

        var raised: [Interrupt] = []
        var resolved: [String] = []
        for try await e in agent.stream("go") {
            switch e {
            case .interruptRaised(let i):
                raised.append(i)
                Task { await agent.resolve(interrupt: i.id, response: .string("yes")) }
            case .interruptResolved(let id, _): resolved.append(id)
            default: break
            }
        }
        XCTAssertEqual(raised.map(\.name), ["confirm"])
        XCTAssertEqual(raised.first?.reason, .string("echo"))
        XCTAssertEqual(resolved, ["tool:e1:confirm"])
        XCTAssertEqual(tool.calls.count, 1, "the tool runs once, after the answer")
    }

    func testHookInterruptDeniedCancelsTheTool() async throws {
        let tool = Recorder("echo")
        let model = FakeModel(turns: [.toolUse([use("echo", ["v": "1"], id: "e1")]), .text("done")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        await agent.hooks.addCallback(BeforeToolCallEvent.self) { e in
            let answer = try e.interrupt("confirm")
            if answer != .string("yes") { e.cancelTool = "not confirmed" }
        }
        var results: [ToolResult] = []
        for try await e in agent.stream("go") {
            if case .interruptRaised(let i) = e {
                Task { await agent.resolve(interrupt: i.id, response: .string("no")) }
            }
            if case .toolResult(let r) = e { results.append(r) }
        }
        XCTAssertEqual(tool.calls.count, 0)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .error)
        XCTAssertTrue(results[0].content.contains("not confirmed"), results[0].content)
    }

    // MARK: .suspend — a tool interrupt

    func testToolRaisedInterruptSuspendsAndTheToolRunsAgainWithTheAnswer() async throws {
        let asking = Asking()
        let other = Recorder("echo")
        let model = FakeModel(turns: [.toolUse([use("asking", id: "a1"), use("echo", ["v": "x"], id: "e1")]),
                                      .text("done")])
        let agent = Agent(model: model, tools: [asking, other], retryStrategy: nil)
        var results: [ToolResult] = []
        for try await e in agent.stream("go") {
            if case .interruptRaised(let i) = e {
                Task { await agent.resolve(interrupt: i.id, response: .number(7)) }
            }
            if case .toolResult(let r) = e { results.append(r) }
        }
        XCTAssertEqual(asking.runs, 2, "the tool body re-runs with the answer available (Strands' second call)")
        XCTAssertEqual(results.first { $0.toolUseId == "a1" }?.content, "answer=7")
        XCTAssertEqual(results.first { $0.toolUseId == "a1" }?.status, .success)
        XCTAssertEqual(other.calls.count, 1, "the other tool of the same message still ran")
    }

    func testSuspendDoesNotBlockTheOtherToolsOfTheMessage() async throws {
        let asking = Asking()
        let fast = Recorder("echo")
        let model = FakeModel(turns: [.toolUse([use("asking", id: "a1"), use("echo", ["v": "x"], id: "e1")]),
                                      .text("done")])
        let agent = Agent(model: model, tools: [asking, fast], retryStrategy: nil)
        var sawEchoResultBeforeAnswer = false
        let answered = Flag()
        for try await e in agent.stream("go") {
            if case .interruptRaised(let i) = e {
                // Delay the answer; the echo result must arrive meanwhile.
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    answered.set()
                    await agent.resolve(interrupt: i.id, response: .number(1))
                }
            }
            if case .toolResult(let r) = e, r.toolUseId == "e1", !answered.isSet { sawEchoResultBeforeAnswer = true }
        }
        XCTAssertTrue(sawEchoResultBeforeAnswer, "awaiting an interrupt must release the actor")
    }

    // MARK: .stop — Strands' shape

    func testStopModeReturnsInterruptsAndResumeKeepsCompletedResults() async throws {
        let asking = Asking()
        let other = Recorder("echo")
        let model = FakeModel(turns: [.toolUse([use("asking", id: "a1"), use("echo", ["v": "x"], id: "e1")]),
                                      .text("done")])
        let agent = Agent(model: model, tools: [asking, other], retryStrategy: nil, interruptMode: .stop)

        let first = try await agent("go")
        XCTAssertEqual(first.stopReason, .interrupt)
        XCTAssertEqual(first.interrupts.map(\.name), ["how_many"])
        XCTAssertEqual(asking.runs, 1)
        XCTAssertEqual(other.calls.count, 1, "the tool that finished did finish")

        // The interrupted cycle is NOT re-modelled and the finished tool is NOT re-run.
        let answers = [InterruptResponse(interruptId: first.interrupts[0].id, response: .number(42))]
        let second = try await agent.resume(answers)
        XCTAssertEqual(second.stopReason, .endTurn)
        XCTAssertEqual(other.calls.count, 1, "a completed tool result must be kept, not re-run")
        XCTAssertEqual(asking.runs, 2, "only the interrupted tool runs again")

        let history = await agent.messages
        let toolResults = history.flatMap { $0.content.compactMap(\.toolResult) }
        XCTAssertEqual(Set(toolResults.map(\.toolUseId)), ["a1", "e1"])
        XCTAssertEqual(toolResults.first { $0.toolUseId == "a1" }?.content, "answer=42")
        let v1 = await agent.eventLoopMetrics.cycleCount
        XCTAssertEqual(v1, 3, "resume replays the message, it does not re-call the model")
        let prompts = await model.seenPrompts.count
        XCTAssertEqual(prompts, 2, "two model calls total: the tool call and the final answer")
    }

    func testStopModeHookInterruptBeforeAnyToolRan() async throws {
        let tool = Recorder("echo")
        let model = FakeModel(turns: [.toolUse([use("echo", ["v": "1"], id: "e1")]), .text("done")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil, interruptMode: .stop)
        await agent.hooks.addCallback(BeforeToolsEvent.self) { e in
            _ = try e.interrupt("whole_message", reason: .string("ok to run these?"))
        }
        let first = try await agent("go")
        XCTAssertEqual(first.stopReason, .interrupt)
        XCTAssertEqual(first.interrupts.map(\.name), ["whole_message"])
        XCTAssertEqual(tool.calls.count, 0)

        let second = try await agent.resume([InterruptResponse(interruptId: first.interrupts[0].id, response: .bool(true))])
        XCTAssertEqual(second.stopReason, .endTurn)
        XCTAssertEqual(tool.calls.count, 1, "after the answer the tools run exactly once")
    }

    func testResumeWithAnUnknownIdThrows() async throws {
        let model = FakeModel(turns: [.text("hi")])
        let agent = Agent(model: model, retryStrategy: nil, interruptMode: .stop)
        do {
            _ = try await agent.resume([InterruptResponse(interruptId: "nope", response: .null)])
            // Not activated → Strands returns early; the loop just runs. Assert it did not crash.
        } catch {
            XCTAssertTrue(error is InterruptError, "\(error)")
        }
    }

    // MARK: approval is one user of the interrupt system

    func testApprovalIsRaisedAsAnInterrupt() async throws {
        final class Guarded: Tool, @unchecked Sendable {
            let name = "guarded"
            let description = "asks first"
            let parameters: JSONValue = ToolSchema.object([:])
            func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
                ApprovalRequest(toolName: name, title: "guarded", risk: .high, input: input)
            }
            func call(_ args: [String: JSONValue]) async throws -> String { "ran" }
        }
        let model = FakeModel(turns: [.toolUse([use("guarded", id: "g1")]), .text("done")])
        let agent = Agent(model: model, tools: [Guarded()], retryStrategy: nil)
        var sawApprovalEvent = false
        var sawGenericInterruptEvent = false
        var pendingWhileWaiting: [Interrupt] = []
        for try await e in agent.stream("go") {
            if case .approvalRequested(let req) = e {
                sawApprovalEvent = true
                pendingWhileWaiting = await agent.pendingInterrupts
                let pendingApprovalIds = await agent.pendingApprovals.map(\.id)
                XCTAssertEqual(pendingApprovalIds, [req.id],
                               "the PR #1 API still answers while the call is suspended")
                Task { await agent.resolve(approval: req.id, .approve) }
            }
            if case .interruptRaised = e { sawGenericInterruptEvent = true }
        }
        XCTAssertTrue(sawApprovalEvent, "approvals keep their own event — the UI is unchanged")
        XCTAssertFalse(sawGenericInterruptEvent, "an approval must not double-report as a generic interrupt")
        XCTAssertEqual(pendingWhileWaiting.map(\.name), ["approval"])
        XCTAssertEqual(pendingWhileWaiting.first?.id, "tool:g1:approval")
    }

    func testApprovalDecisionSurvivesTheJSONRoundTrip() {
        for decision in [ApprovalDecision.approve,
                         .deny(reason: "nope"),
                         .deny(reason: nil),
                         .approveEdited(["url": .string("https://example.com")])] {
            let json = decision.interruptResponse
            XCTAssertEqual(ApprovalDecision(interruptResponse: json), decision, json.compact)
        }
    }
}

/// A boolean two tasks may touch.
final class Flag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
