import XCTest
import Loopl

/// Strands `_estimate_input_tokens`: the last model call's measured usage is a
/// baseline, and only the messages added since it are estimated. Cheaper than
/// re-walking the transcript every cycle, and closer to the truth because the
/// baseline already contains the system prompt and the tool specs.
final class UsageBaselineTests: XCTestCase {

    func use(_ name: String, id: String = ToolUse.makeId()) -> ToolUse {
        ToolUse(toolUseId: id, name: name, input: [:])
    }

    /// Records the `projectedInputTokens` the agent put on each BeforeModelCallEvent.
    final class Projected: @unchecked Sendable {
        private var values: [Int] = []
        private let lock = NSLock()
        func add(_ n: Int) { lock.lock(); values.append(n); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// One observation of a cycle: what was projected, the baseline in force at
    /// that moment, and the messages the projection was made from.
    struct Cycle: Sendable { var projected: Int; var baseline: Int; var messages: [Message] }
    final class Cycles: @unchecked Sendable {
        private var items: [Cycle] = []
        private let lock = NSLock()
        func add(_ c: Cycle) { lock.lock(); items.append(c); lock.unlock() }
        var all: [Cycle] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testFirstCycleEstimatesEverythingSecondUsesTheBaseline() async throws {
        let echo = ClosureTool(name: "echo", description: "echo a thing") { _ in String(repeating: "x", count: 400) }
        let system = String(repeating: "system ", count: 200)
        let model = FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("done")])
        let agent = Agent(model: model, tools: [echo], systemPrompt: system, retryStrategy: nil)
        let cycles = Cycles()
        await agent.hooks.addCallback(BeforeModelCallEvent.self) { [cycles] e in
            let baseline = await agent.eventLoopMetrics.usageBaselineTokens
            cycles.add(Cycle(projected: e.projectedInputTokens, baseline: baseline, messages: e.messages))
        }

        _ = try await agent("hello")
        let observed = cycles.all
        XCTAssertEqual(observed.count, 2)

        // Cycle 1 — cold start: the whole transcript, system prompt and tool specs included.
        XCTAssertEqual(observed[0].baseline, 0)
        XCTAssertEqual(observed[0].projected,
                       TokenEstimator.estimate(messages: observed[0].messages, systemPrompt: system,
                                               toolSpecs: [echo.toolSpec]),
                       "cold start = the old full estimate")

        // Cycle 2 — the runtime's measured usage plus ONLY the messages added since.
        XCTAssertGreaterThan(observed[1].baseline, 0, "the runtime's own count becomes the baseline")
        let tail = observed[1].messages.drop { $0.role != .assistant }.dropFirst()   // after the assistant turn
        let tailEstimate = tail.reduce(0) { $0 + TokenEstimator.estimate($1) }
        XCTAssertEqual(observed[1].projected, observed[1].baseline + tailEstimate,
                       "baseline + new messages — no re-walk of the transcript, no second system prompt")
        XCTAssertGreaterThan(tailEstimate, 0, "there IS a new message (the 400-char tool result)")
    }

    func testBaselineIsNotSetWhenTheRuntimeReportsNothing() async throws {
        // A turn whose metrics carry no token counts cannot become a baseline (honesty over a guess).
        let model = FakeModel(turns: [.failure(ModelError("cold")), .text("ok")])
        let agent = Agent(model: model, retryStrategy: nil)
        _ = try? await agent("hello")
        let v1 = await agent.eventLoopMetrics.usageBaselineTokens
        XCTAssertEqual(v1, 0)
    }

    func testProjectionFallsBackWhenTheBaselineMessageIsGone() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let model = FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("one"),
                                      .toolUse([use("echo", id: "e2")]), .text("two")])
        let agent = Agent(model: model, tools: [echo], retryStrategy: nil)
        _ = try await agent("first")
        let baselineAfterFirst = await agent.eventLoopMetrics.usageBaselineTokens
        XCTAssertGreaterThan(baselineAfterFirst, 0)

        // A host replacing the history (session restore, a trim) drops the baseline message:
        // the next projection must fall back to a full estimate rather than add to a stale number.
        await agent.setMessages([.user("fresh start")])
        let projected = Projected()
        await agent.hooks.addCallback(BeforeModelCallEvent.self) { e in projected.add(e.projectedInputTokens) }
        _ = try await agent("second")

        let full = TokenEstimator.estimate(messages: [.user("fresh start"), .user("second")],
                                           systemPrompt: nil, toolSpecs: [echo.toolSpec])
        XCTAssertEqual(projected.all.first, full, "fallback = the old full estimate, exactly")
    }

    func testBaselineTracksTheLatestModelCall() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let model = FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("done")])
        let agent = Agent(model: model, tools: [echo], retryStrategy: nil)
        _ = try await agent("hello")
        let first = await agent.eventLoopMetrics.usageBaselineTokens

        await model.appendTurns([.text("again")])
        _ = try await agent("another question")
        let second = await agent.eventLoopMetrics.usageBaselineTokens
        XCTAssertGreaterThan(second, 0)
        XCTAssertNotEqual(second, first, "the baseline moves with the newest model call")
    }
}
