import XCTest
import Loopl

/// `AfterToolsEvent` is Strands' `finally`: it fires once for every
/// `BeforeToolsEvent`, whatever happened in between. Plus the two early-stop
/// routes a hook has after tools ran (`endTurn`, `requestState.stopEventLoop`).
final class AfterToolsTests: XCTestCase {

    func use(_ name: String, _ args: [String: JSONValue] = [:], id: String = ToolUse.makeId()) -> ToolUse {
        ToolUse(toolUseId: id, name: name, input: args)
    }

    /// Thread-safe tally of the Before/After pairs a run produced.
    final class Pairs: @unchecked Sendable {
        private var items: [String] = []
        private let lock = NSLock()
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    func agentWithPairs(_ turns: [FakeModel.Turn], tools: [any Tool] = []) async -> (Agent, Pairs) {
        let pairs = Pairs()
        let agent = Agent(model: FakeModel(turns: turns), tools: tools, retryStrategy: nil)
        await agent.hooks.addCallback(BeforeToolsEvent.self) { _ in pairs.add("before") }
        await agent.hooks.addCallback(AfterToolsEvent.self) { _ in pairs.add("after") }
        return (agent, pairs)
    }

    // MARK: always paired

    func testPairedOnTheHappyPath() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let (agent, pairs) = await agentWithPairs([.toolUse([use("echo", id: "e1")]), .text("done")], tools: [echo])
        for try await _ in agent.stream("go") {}
        XCTAssertEqual(pairs.all, ["before", "after"])
    }

    func testPairedWhenATooThrows() async throws {
        let bad = ClosureTool(name: "bad", description: "throws") { _ in throw Boom() }
        let (agent, pairs) = await agentWithPairs([.toolUse([use("bad", id: "b1")]), .text("done")], tools: [bad])
        var results: [ToolResult] = []
        for try await e in agent.stream("go") { if case .toolResult(let r) = e { results.append(r) } }
        XCTAssertEqual(pairs.all, ["before", "after"])
        XCTAssertEqual(results.first?.status, .error)
        XCTAssertTrue(results.first?.content.contains("boom") == true, results.first?.content ?? "")
    }

    /// The path Strands' `finally` exists for: a BeforeTools hook that blows up.
    func testPairedWhenABeforeToolsHookThrows() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let pairs = Pairs()
        let agent = Agent(model: FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("done")]),
                          tools: [echo], retryStrategy: nil)
        await agent.hooks.addCallback(BeforeToolsEvent.self) { _ in
            pairs.add("before")
            throw Boom()
        }
        await agent.hooks.addCallback(AfterToolsEvent.self) { _ in pairs.add("after") }

        do {
            for try await _ in agent.stream("go") {}
            XCTFail("the hook's error must reach the caller")
        } catch {
            XCTAssertTrue(error is Boom, "\(error)")
        }
        XCTAssertEqual(pairs.all, ["before", "after"], "AfterTools must fire even when BeforeTools threw")
    }

    func testPairedWhenABeforeToolsHookCancels() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let (agent, pairs) = await agentWithPairs([.toolUse([use("echo", id: "e1")]), .text("done")], tools: [echo])
        await agent.hooks.addCallback(BeforeToolsEvent.self) { e in e.cancel = "not now" }
        var results: [ToolResult] = []
        for try await e in agent.stream("go") { if case .toolResult(let r) = e { results.append(r) } }
        XCTAssertEqual(pairs.all, ["before", "after"])
        XCTAssertEqual(results.first?.content, "not now")
    }

    func testPairedWhenTheLoopStopsForAnInterrupt() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let pairs = Pairs()
        let agent = Agent(model: FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("done")]),
                          tools: [echo], retryStrategy: nil, interruptMode: .stop)
        await agent.hooks.addCallback(BeforeToolsEvent.self) { e in
            pairs.add("before")
            _ = try e.interrupt("ask")
        }
        await agent.hooks.addCallback(AfterToolsEvent.self) { _ in pairs.add("after") }
        let result = try await agent("go")
        XCTAssertEqual(result.stopReason, .interrupt)
        XCTAssertEqual(pairs.all, ["before", "after"])
    }

    /// An interrupt stop must not append a tool-result turn (the cycle is not finished).
    func testInterruptStopDoesNotAppendTheToolResultMessage() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let agent = Agent(model: FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("done")]),
                          tools: [echo], retryStrategy: nil, interruptMode: .stop)
        await agent.hooks.addCallback(BeforeToolsEvent.self) { e in _ = try e.interrupt("ask") }
        _ = try await agent("go")
        let history = await agent.messages
        XCTAssertFalse(history.contains { $0.role == .user && $0.content.contains { $0.isToolResult } })
    }

    // MARK: early stop

    func testEndTurnStopsWithoutCallingTheModelAgain() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let model = FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("the model should never say this")])
        let agent = Agent(model: model, tools: [echo], retryStrategy: nil)
        await agent.hooks.addCallback(AfterToolsEvent.self) { e in e.endTurn = .text("stopped by the hook") }

        let result = try await agent("go")
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertEqual(result.text, "stopped by the hook")
        let v1 = await model.seenPrompts.count
        XCTAssertEqual(v1, 1, "no second model call")
        let v2 = await agent.messages.last?.text
        XCTAssertEqual(v2, "stopped by the hook")
    }

    func testEndTurnFlagUsesTheNeutralLine() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let agent = Agent(model: FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("nope")]),
                          tools: [echo], retryStrategy: nil)
        await agent.hooks.addCallback(AfterToolsEvent.self) { e in e.endTurn = .flag }
        let result = try await agent("go")
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertTrue(result.text.contains("Turn ended early by hook"), result.text)
    }

    func testEndTurnWithContentBlocks() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let agent = Agent(model: FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("nope")]),
                          tools: [echo], retryStrategy: nil)
        await agent.hooks.addCallback(AfterToolsEvent.self) { e in
            e.endTurn = .content([.text("a"), .text("b")])
        }
        let result = try await agent("go")
        XCTAssertEqual(result.message.content.count, 2)
        XCTAssertEqual(result.message.content.compactMap(\.text), ["a", "b"])
    }

    func testStopEventLoopKeepsTheCyclesStopReason() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let model = FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("never reached")])
        let agent = Agent(model: model, tools: [echo], retryStrategy: nil)
        await agent.hooks.addCallback(AfterToolsEvent.self) { e in
            e.requestState["stopEventLoop"] = .bool(true)
        }
        let result = try await agent("go")
        XCTAssertEqual(result.stopReason, .toolUse, "Strands stops with the cycle's own stop reason")
        let v3 = await model.seenPrompts.count
        XCTAssertEqual(v3, 1)
        let v4 = await agent.requestState["stopEventLoop"]
        XCTAssertEqual(v4, .bool(true))
        // The tool-result turn IS appended — the cycle finished, the loop just does not recurse.
        let history = await agent.messages
        XCTAssertTrue(history.contains { $0.role == .user && $0.content.contains { $0.isToolResult } })
    }

    func testNoEarlyStopRecursesAsBefore() async throws {
        let echo = ClosureTool(name: "echo", description: "echo") { _ in "ok" }
        let model = FakeModel(turns: [.toolUse([use("echo", id: "e1")]), .text("final")])
        let agent = Agent(model: model, tools: [echo], retryStrategy: nil)
        let result = try await agent("go")
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertEqual(result.text, "final")
        let v5 = await model.seenPrompts.count
        XCTAssertEqual(v5, 2)
    }
}
