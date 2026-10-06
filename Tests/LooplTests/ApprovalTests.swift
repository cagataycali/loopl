import XCTest
import Loopl

/// Human-in-the-loop: a flagged tool call suspends inside the actor until
/// `resolve(approval:)`, the timeout, or cancellation; the other tools of the
/// message keep running.
final class ApprovalTests: XCTestCase {
    func use(_ name: String, _ args: [String: JSONValue] = [:], id: String = ToolUse.makeId()) -> ToolUse {
        ToolUse(toolUseId: id, name: name, input: args)
    }

    /// A tool that always asks, records what it ran with.
    final class Guarded: Tool, @unchecked Sendable {
        let name = "guarded"
        let description = "asks first"
        let parameters: JSONValue = ToolSchema.object(["value": ToolSchema.string("v")])
        private var _ran: [[String: JSONValue]] = []
        private let lock = NSLock()
        var ran: [[String: JSONValue]] { lock.withLock { _ran } }
        private func record(_ a: [String: JSONValue]) { lock.withLock { _ran.append(a) } }
        func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
            ApprovalRequest(toolName: name, title: "guarded \(input["value"]?.stringValue ?? "")", risk: input["value"]?.stringValue == "read" ? .low : .medium, input: input)
        }
        func call(_ args: [String: JSONValue]) async throws -> String {
            record(args)
            return "ran \(args["value"]?.stringValue ?? "")"
        }
    }

    /// Drive the agent, answering approvals through `decide` as they arrive. Returns every event.
    func run(_ agent: Agent, _ prompt: String = "go", decide: @escaping @Sendable (ApprovalRequest) async -> ApprovalDecision?) async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for try await e in agent.stream(prompt) {
            events.append(e)
            if case .approvalRequested(let req) = e {
                Task { if let d = await decide(req) { await agent.resolve(approval: req.id, d) } }
            }
        }
        return events
    }
    func results(_ events: [AgentEvent]) -> [ToolResult] { events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil } }
    func kinds(_ events: [AgentEvent]) -> [String] {
        events.compactMap { e in
            switch e {
            case .approvalRequested(let r): "ask:\(r.id)"
            case .approvalResolved(let id, let d): "answer:\(id):\(d.isApproved ? "ok" : "no")"
            case .toolStarted(let u): "start:\(u.toolUseId)"
            case .toolResult(let r): "result:\(r.toolUseId)"
            case .result: "end"
            default: nil
            }
        }
    }

    // MARK: suspend / resume

    func testApproveResumesTheCall() async throws {
        let tool = Guarded()
        let model = FakeModel(turns: [.toolUse([use("guarded", ["value": "write"], id: "g1")]), .text("done")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        let events = try await run(agent) { _ in .approve }
        XCTAssertEqual(kinds(events), ["ask:g1", "answer:g1:ok", "start:g1", "result:g1", "end"])
        XCTAssertEqual(results(events).map(\.content), ["ran write"])
        let req = events.compactMap { if case .approvalRequested(let r) = $0 { return r }; return nil }.first
        XCTAssertEqual(req?.id, "g1"); XCTAssertEqual(req?.toolName, "guarded"); XCTAssertEqual(req?.risk, .medium)
        XCTAssertEqual(req?.input["value"]?.stringValue, "write")
        let pending = await agent.pendingApprovals
        XCTAssertTrue(pending.isEmpty)
    }

    func testDenyBecomesAnErrorResultAndTheLoopContinues() async throws {
        let tool = Guarded()
        let model = FakeModel(turns: [.toolUse([use("guarded", ["value": "write"], id: "g1")]), .text("ok, skipped")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        let events = try await run(agent) { _ in .deny(reason: "not today") }
        XCTAssertEqual(kinds(events), ["ask:g1", "answer:g1:no", "result:g1", "end"], "a denied call never starts")
        let r = results(events)[0]
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.content.contains("denied by the user"), r.content)
        XCTAssertTrue(r.content.contains("not today"))
        XCTAssertTrue(tool.ran.isEmpty)
        let final = events.compactMap { if case .result(let r) = $0 { return r }; return nil }.first
        XCTAssertEqual(final?.text, "ok, skipped")
        // History carries the denial as a toolResult so the model is told.
        let msgs = await agent.messages
        XCTAssertEqual(msgs[2].toolResults.first?.status, .error)
    }

    func testTimeoutDenies() async throws {
        let tool = Guarded()
        let model = FakeModel(turns: [.toolUse([use("guarded", ["value": "write"], id: "g1")]), .text("ok")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil, approvalTimeout: 0.15)
        let t0 = Date()
        let events = try await run(agent) { _ in nil }     // nobody answers
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
        XCTAssertEqual(kinds(events), ["ask:g1", "answer:g1:no", "result:g1", "end"])
        XCTAssertTrue(results(events)[0].content.contains("no answer within"))
        XCTAssertTrue(tool.ran.isEmpty)
    }

    func testEditedInputRunsTheEdit() async throws {
        let tool = Guarded()
        let model = FakeModel(turns: [.toolUse([use("guarded", ["value": "write"], id: "g1")]), .text("ok")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        let events = try await run(agent) { _ in .approveEdited(["value": "edited"]) }
        XCTAssertEqual(results(events).map(\.content), ["ran edited"])
        XCTAssertEqual(tool.ran, [["value": "edited"]])
        let started = events.compactMap { if case .toolStarted(let u) = $0 { return u }; return nil }.first
        XCTAssertEqual(started?.input["value"]?.stringValue, "edited", ".toolStarted carries the edited input")
    }

    func testOtherConcurrentToolsFinishWhileOneWaits() async throws {
        let tool = Guarded()
        let model = FakeModel(turns: [.toolUse([use("guarded", ["value": "write"], id: "g1"),
                                                use("calculator", ["expression": "2+2"], id: "c1")]), .text("ok")])
        let agent = Agent(model: model, tools: [tool, CalculatorTool()], retryStrategy: nil)
        let events = try await run(agent) { _ in
            try? await Task.sleep(nanoseconds: 150_000_000)
            return .approve
        }
        let k = kinds(events)
        // The invariant is the suspend releasing the actor — NOT an exact interleaving: whether
        // `start:c1` is emitted just before or just after `ask:g1` is a race between two
        // concurrent tool tasks, and asserting the exact index made this test flaky on the
        // simulator (it passed under `swift test` on the same commit).
        XCTAssertLessThan(k.firstIndex(of: "result:c1")!, k.firstIndex(of: "answer:g1:ok")!,
                          "the calculator ran and finished while the guarded call waited: \(k)")
        XCTAssertGreaterThan(k.firstIndex(of: "start:g1")!, k.firstIndex(of: "answer:g1:ok")!,
                             "the guarded tool only starts once the human answered: \(k)")
        let msgs = await agent.messages
        XCTAssertEqual(msgs[2].toolResults.map(\.toolUseId), ["g1", "c1"], "toolResult message keeps toolUse order")
        XCTAssertEqual(msgs[2].toolResults.map(\.content), ["ran write", "2+2 = 4"])
    }

    func testPendingApprovalsIsVisibleWhileWaitingAndResolveIsIdempotent() async throws {
        let tool = Guarded()
        let model = FakeModel(turns: [.toolUse([use("guarded", ["value": "write"], id: "g1")]), .text("ok")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        let task = Task { try await agent("go") }
        var seen: [ApprovalRequest] = []
        for _ in 0..<50 { seen = await agent.pendingApprovals; if !seen.isEmpty { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(seen.map(\.id), ["g1"])
        let first = await agent.resolve(approval: "g1", .approve)
        let second = await agent.resolve(approval: "g1", .deny(reason: nil))
        XCTAssertTrue(first); XCTAssertFalse(second, "a second answer is ignored")
        let unknown = await agent.resolve(approval: "nope", .approve)
        XCTAssertFalse(unknown)
        _ = try await task.value
        XCTAssertEqual(tool.ran.count, 1)
    }

    func testCancellationWhileWaitingDenies() async throws {
        let tool = Guarded()
        let model = FakeModel(turns: [.toolUse([use("guarded", ["value": "write"], id: "g1")]), .text("ok")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        let task = Task { () -> Int in
            var n = 0
            for try await _ in agent.stream("go") { n += 1 }
            return n
        }
        for _ in 0..<50 { if !(await agent.pendingApprovals.isEmpty) { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        task.cancel()
        _ = try? await task.value
        XCTAssertTrue(tool.ran.isEmpty, "a cancelled wait never runs the tool")
        let left = await agent.pendingApprovals
        XCTAssertTrue(left.isEmpty)
    }

    // MARK: policy hook

    func testPolicyMutatingAutoApprovesLowRisk() async throws {
        let tool = Guarded()
        let model = FakeModel(turns: [.toolUse([use("guarded", ["value": "read"], id: "r"), use("guarded", ["value": "write"], id: "w")]), .text("ok")])
        let agent = Agent(model: model, tools: [tool], hooks: [ApprovalPolicy(mode: .mutating)], retryStrategy: nil)
        let events = try await run(agent) { _ in .approve }
        let asked = events.compactMap { if case .approvalRequested(let r) = $0 { return r.id }; return nil }
        XCTAssertEqual(asked, ["w"], "reads pass, writes ask")
        XCTAssertEqual(tool.ran.count, 2)
    }

    func testPolicyNeverAndAlways() async throws {
        for (mode, expectedAsks) in [(ApprovalPolicy.Mode.never, 0), (.always, 2)] {
            let tool = Guarded()
            let model = FakeModel(turns: [.toolUse([use("guarded", ["value": "read"], id: "r"), use("guarded", ["value": "write"], id: "w")]), .text("ok")])
            let agent = Agent(model: model, tools: [tool], hooks: [ApprovalPolicy(mode: mode)], retryStrategy: nil)
            let events = try await run(agent) { _ in .approve }
            XCTAssertEqual(events.filter { if case .approvalRequested = $0 { return true }; return false }.count, expectedAsks, "\(mode)")
            XCTAssertEqual(tool.ran.count, 2)
        }
    }

    func testPolicyTrustedHostAutoApproves() async throws {
        let model = FakeModel(turns: [.toolUse([use("http", ["method": "POST", "url": "https://api.example.com/x", "body": "hi"], id: "h")]), .text("ok")])
        // The call itself is refused (offline), but it must not ASK: the host is trusted.
        NetworkPolicy.setOffline(true); defer { NetworkPolicy.setOffline(false) }
        let agent = Agent(model: model, tools: [HttpTool()], hooks: [ApprovalPolicy(mode: .always, trustedHosts: ["example.com"])], retryStrategy: nil)
        let events = try await run(agent) { _ in .deny(reason: "should not be asked") }
        XCTAssertTrue(events.allSatisfy { if case .approvalRequested = $0 { return false }; return true })
        XCTAssertTrue(results(events)[0].content.contains("offline"))
    }

    func testHookCanDemandApprovalForAnyTool() async throws {
        let hooks = ClosureHooks { r in
            r.addCallback(BeforeToolCallEvent.self) { e in
                if e.toolUse.name == "calculator" { e.approval = ApprovalRequest(toolName: "calculator", title: "compute?", risk: .low) }
            }
        }
        let model = FakeModel(turns: [.toolUse([use("calculator", ["expression": "6*7"], id: "c")]), .text("ok")])
        let agent = Agent(model: model, tools: [CalculatorTool()], hooks: [hooks], retryStrategy: nil)
        let events = try await run(agent) { req in
            XCTAssertEqual(req.id, "c"); XCTAssertEqual(req.input["expression"]?.stringValue, "6*7", "input is filled from the toolUse")
            return .approve
        }
        XCTAssertEqual(results(events).map(\.content), ["6*7 = 42"])
    }

    // MARK: transcript

    func testTranscriptFoldsApprovalCards() {
        var t = Transcript()
        t.user("go")
        let req = ApprovalRequest(id: "g1", toolName: "http", title: "POST api.example.com", risk: .medium)
        t.apply(.approvalRequested(req))
        XCTAssertEqual(t.pendingApprovals.map(\.id), ["g1"])
        t.apply(.approvalRequested(req))
        XCTAssertEqual(t.items.count, 2, "no duplicate card")
        t.apply(.approvalResolved(id: "g1", .deny(reason: "no")))
        XCTAssertTrue(t.pendingApprovals.isEmpty)
        guard case .approval(let r, let d) = t.items[1].kind else { return XCTFail() }
        XCTAssertEqual(r.id, "g1"); XCTAssertEqual(d, .deny(reason: "no"))
    }

    func testRedactHidesCredentials() {
        let h = ApprovalRequest.redact(["Authorization": "Bearer abc", "X-Api-Key": "k", "Cookie": "s=1", "Accept": "application/json"])
        XCTAssertEqual(h["Authorization"], "•••"); XCTAssertEqual(h["X-Api-Key"], "•••"); XCTAssertEqual(h["Cookie"], "•••")
        XCTAssertEqual(h["Accept"], "application/json")
    }
}
