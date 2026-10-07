import XCTest
import Loopl

/// STOP-LOCATION 2026-10-07 — the stop button. Owner on build 15: "stop button is not working properly".
/// Root cause: a tool parked on a continuation that never resumes (a permission dialog with no run loop behind it,
/// a location fix that never comes) never observed cancellation, so the turn could not end; and cancelling the task
/// that ITERATES `stream()` ends the iteration with nil — the host never got `.result`, `isRunning` stayed true.
final class StopTests: XCTestCase {
    func use(_ name: String, _ args: [String: JSONValue] = [:], id: String = ToolUse.makeId()) -> ToolUse {
        ToolUse(toolUseId: id, name: name, input: args)
    }
    /// A tool that awaits a continuation nobody ever resumes and ignores cancellation — like the old location tool.
    static func neverReturns() -> ClosureTool {
        ClosureTool(name: "never", description: "parks forever", parameters: ToolSchema.object([:])) { _ in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return "unreachable"
        }
    }

    /// `cancelRun()` during a never-returning tool: the turn ends well under a second, with the cancelled tool result
    /// AND the `.result(.cancelled)` event delivered to the (uncancelled) host iteration.
    func testCancelRunDuringHungToolEndsTurnWithinASecond() async throws {
        let model = FakeModel(turns: [.toolUse([use("never", id: "t1")]), .text("never reached")])
        let agent = Agent(model: model, tools: [Self.neverReturns()], retryStrategy: nil)
        let t0 = Date()
        var events: [AgentEvent] = []
        var cancelledAt: Date?
        for try await e in agent.stream("hang") {
            events.append(e)
            if case .toolStarted = e { cancelledAt = Date(); agent.cancelRun() }
        }
        XCTAssertNotNil(cancelledAt)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt ?? t0), 1.0, "stop must end the turn immediately")
        let results = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }
        XCTAssertEqual(results.map(\.content), ["Tool execution cancelled"])
        XCTAssertTrue(results[0].isError)
        guard case .result(let r)? = events.last else { return XCTFail("host must still receive .result, got \(String(describing: events.last))") }
        XCTAssertEqual(r.stopReason, .cancelled)
        // History stays well-formed: assistant(toolUse) + user(toolResult), so the next turn is a clean request.
        let history = await agent.messages
        XCTAssertEqual(history.map(\.role), [.user, .assistant, .user])
        XCTAssertFalse(agent.isRunning)
        // The agent is usable right after.
        var texts: [String] = []
        for try await e in agent.stream("again") { if case .text(let t) = e { texts.append(t) } }
        XCTAssertFalse(texts.isEmpty)
    }

    /// `cancelRun()` mid-text: the host iteration sees `.result(.cancelled)` (the old path returned nil to a cancelled iterator).
    func testCancelRunMidTextDeliversCancelledResult() async throws {
        let model = FakeModel(turns: [.hang(after: 3)])
        let agent = Agent(model: model, retryStrategy: nil)
        var seen = 0
        var result: AgentResult?
        let t0 = Date()
        for try await e in agent.stream("x") {
            if case .text = e { seen += 1; if seen == 3 { agent.cancelRun() } }
            if case .result(let r) = e { result = r }
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0)
        XCTAssertEqual(seen, 3)
        XCTAssertEqual(result?.stopReason, .cancelled)
        let history = await agent.messages
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[1].role, .assistant)
    }

    /// A parent queued on the model gate behind a busy child: stop returns at once and the gate is left to its owner.
    func testCancelWhileQueuedOnModelGateReleasesNothing() async throws {
        let gate = ModelGate()
        try await gate.acquire()                       // someone else generates
        let waiter = Task { try await gate.acquire() }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(gate.waiting, 1)
        waiter.cancel()
        do { try await waiter.value; XCTFail("must throw") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.waiting, 0)
        XCTAssertTrue(gate.isBusy, "the owner still holds it")
        gate.release()
        XCTAssertFalse(gate.isBusy)
    }

    /// `Transcript.stopped()` — the host's fallback when the agent cannot end: open rows settle, nothing pending remains.
    func testTranscriptStoppedSettlesOpenRows() {
        var t = Transcript()
        t.user("where am I?")
        t.apply(.toolStarted(use("location", id: "l1")))
        t.apply(.approvalRequested(ApprovalRequest(id: "a1", toolName: "http", title: "GET", input: [:])))
        t.stopped()
        XCTAssertFalse(t.isRunning)
        XCTAssertTrue(t.pendingApprovals.isEmpty)
        let open = t.items.filter { if case .toolUse(_, nil) = $0.kind { return true }; return false }
        XCTAssertTrue(open.isEmpty)
        guard case .note(let n)? = t.items.last?.kind else { return XCTFail("note expected") }
        XCTAssertEqual(n, "stopped")
    }
}
