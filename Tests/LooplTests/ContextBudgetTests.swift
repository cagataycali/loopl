import XCTest
import Loopl

/// Per-runtime context budgeting + the single context-overflow recovery.
/// The pin: a long, tool-heavy conversation against an FM-sized model
/// (4096 tokens) must never exceed the budget and never error.
final class ContextBudgetTests: XCTestCase {
    /// A model whose only job is to look like Apple Foundation Models.
    actor FMSizedModel: Model {
        nonisolated let kind: RuntimeKind = .appleFM
        nonisolated static var contextCeiling: Int { 4096 }
        private(set) var loadedModelId: String?
        private(set) var params = GenerationParams()      // contextLength stays the 8192 default on purpose
        func updateConfig(_ params: GenerationParams) { self.params = params }
        func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {}
        func unload() async {}
        nonisolated static func availability() -> RuntimeAvailability { .ok }
        nonisolated func stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// A tool that returns a fat result — the usual reason a 4096-token window blows up.
    func fatTool(_ name: String, chars: Int = 2400) -> ClosureTool {
        ClosureTool(name: name, description: "returns a lot of text",
                    parameters: ToolSchema.object(["q": ToolSchema.string("q")])) { _ in
            String(repeating: "lorem ipsum dolor sit amet ", count: max(1, chars / 27))
        }
    }

    func use(_ name: String, _ i: Int) -> ToolUse {
        ToolUse(toolUseId: "t\(name)\(i)", name: name, input: ["q": .string("x")])
    }

    // MARK: per-runtime window

    /// The ceiling clamps a runtime even when the loaded spec asks for more.
    func testContextWindowIsPerRuntime() async {
        let fm = FMSizedModel()
        var p = GenerationParams(); p.contextLength = 32768
        await fm.updateConfig(p)
        let fmWindow = await fm.contextWindow
        XCTAssertEqual(fmWindow, 4096, "Apple FM must report its own 4096-token ceiling, not the spec's 32k")

        let mlx = FakeModel(turns: [], contextLength: 32768)
        let mlxWindow = await mlx.contextWindow
        XCTAssertEqual(mlxWindow, 32768, "a runtime without a ceiling reports the loaded model's window")
        XCTAssertEqual(FakeModel.contextCeiling, Int.max)
    }

    /// The sliding window is sized from the window it is given, not a constant.
    func testWindowSizeDerivesFromContextWindow() {
        let m = SlidingWindowConversationManager()          // windowSize 40, threshold 0.7, 256 tok/message
        XCTAssertEqual(m.windowSize(forContextWindow: 4096), 11)    // 0.7·4096/256
        XCTAssertEqual(m.windowSize(forContextWindow: 8192), 22)
        XCTAssertEqual(m.windowSize(forContextWindow: 32768), 40)   // capped by windowSize
        XCTAssertEqual(m.windowSize(forContextWindow: 512), 4)      // floor
        XCTAssertEqual(m.windowSize(forContextWindow: 0), 40)       // unknown runtime → the constant
    }

    /// Tool results are truncated BEFORE any turn is dropped, and the current
    /// user turn survives both.
    func testToolResultsAreTrimmedBeforeTurns() throws {
        let m = SlidingWindowConversationManager()
        var messages: [Message] = [
            .user("first question"),
            .assistant(text: "", toolUses: [use("fat", 1)]),
            .toolResults([ToolResult(toolUseId: "tfat1", name: "fat", content: String(repeating: "A", count: 3000))]),
            .assistant("answered"),
            .user("current question"),
        ]
        let before = messages.count
        try m.reduceContext(&messages, error: nil)
        XCTAssertEqual(messages.count, before, "the first reduction must truncate a result, not drop a turn")
        XCTAssertEqual(m.truncatedResultCount, 1)
        let result = messages[2].content.compactMap(\.toolResult).first
        XCTAssertLessThan(result?.content.count ?? .max, 600)
        XCTAssertTrue(result?.content.contains("truncated:") == true)

        // Nothing fat left → now turns slide out, and the current user turn stays
        // (it is the question being answered, so the kept history starts with it).
        try m.reduceContext(&messages, error: nil)
        XCTAssertLessThan(messages.count, before)
        XCTAssertEqual(messages.last?.text, "current question")
    }

    func testCurrentUserTurnIsNeverDropped() throws {
        let m = SlidingWindowConversationManager(windowSize: 4, shouldTruncateResults: false)
        var messages: [Message] = (0..<6).map { .user("q\($0)") } + [.user("current")]
        for _ in 0..<10 { try? m.reduceContext(&messages, error: nil) }
        XCTAssertFalse(messages.isEmpty)
        XCTAssertEqual(messages.last?.text, "current")
    }

    // MARK: the pin — 6 turns × 5 fat tools on a 4096-token runtime

    func testLongToolHeavyConversationStaysUnderFMBudget() async throws {
        let names = ["alpha", "bravo", "charlie", "delta", "echo"]
        let tools = names.map { fatTool($0) }
        let manager = SlidingWindowConversationManager()
        // Six turns; every turn calls all five tools, then answers.
        var turns: [FakeModel.Turn] = []
        for i in 0..<6 {
            turns.append(.toolUse(text: "checking", names.map { use($0, i) }))
            turns.append(.text("answer \(i)"))
        }
        let model = FakeModel(turns: turns, contextLength: 4096)
        let agent = Agent(model: model, tools: tools,
                          systemPrompt: "You are loopl. Be brief.",
                          conversationManager: manager,
                          retryStrategy: nil)

        for i in 0..<6 {
            let result = try await agent("question number \(i) about everything")
            XCTAssertEqual(result.stopReason, .endTurn)
            XCTAssertEqual(result.text, "answer \(i)")
        }

        // Every prompt the model actually saw must fit the 4096-token window.
        let prompts = await model.seenPrompts
        let systems = await model.seenSystemPrompts
        let specs = await model.seenToolSpecs
        XCTAssertEqual(prompts.count, 12)
        for (i, p) in prompts.enumerated() {
            let est = TokenEstimator.estimate(messages: p, systemPrompt: systems[i], toolSpecs: specs[i])
            XCTAssertLessThan(est, 4096, "prompt \(i) estimated at \(est) tokens — over the FM window")
            // and under the manager's own budget (0.7 · 4096), which is what it trims to
            XCTAssertLessThanOrEqual(est, Int(0.7 * 4096) + 256, "prompt \(i) over the compression budget: \(est)")
        }
        let metrics = await agent.eventLoopMetrics
        XCTAssertEqual(metrics.contextReductionCount, 0, "proactive trimming should mean no reactive recovery was needed")
        XCTAssertGreaterThan(manager.truncatedResultCount, 0, "fat tool results must have been truncated")
    }

    // MARK: recovery

    /// A context-exceeded error from the runtime is recovered by reducing
    /// context and retrying — exactly once.
    func testContextOverflowIsRecoveredOnce() async throws {
        let manager = SlidingWindowConversationManager()
        let model = FakeModel(turns: [
            .failure(ContextWindowOverflowError("prompt ≈5000 tokens; Apple FM window is 4096")),
            .text("recovered answer"),
        ], contextLength: 1_000_000)      // the fake's own overflow check stays out of the way
        let agent = Agent(model: model, tools: [], messages: longHistory(),
                          conversationManager: manager, retryStrategy: nil)
        let result = try await agent("and now the real question")
        XCTAssertEqual(result.text, "recovered answer")
        let metrics = await agent.eventLoopMetrics
        XCTAssertEqual(metrics.contextReductionCount, 1, "recovered exactly once")
    }

    /// If it still does not fit after one reduction, the caller gets a clear
    /// error — not an endless retry loop.
    func testContextOverflowFailsClearlyAfterOneRetry() async {
        let model = FakeModel(turns: (0..<6).map { _ in .failure(ContextWindowOverflowError("still too long")) },
                              contextLength: 1_000_000)
        let agent = Agent(model: model, tools: [], messages: longHistory(),
                          conversationManager: SlidingWindowConversationManager(), retryStrategy: nil)
        do {
            _ = try await agent("question")
            XCTFail("expected the overflow to surface")
        } catch let e as ContextWindowOverflowError {
            XCTAssertTrue(e.message.contains("context was reduced 1 time(s)"), "unclear error: \(e.message)")
        } catch {
            XCTFail("wrong error: \(error)")
        }
        let metrics = await agent.eventLoopMetrics
        XCTAssertEqual(metrics.contextReductionCount, 1, "one reduction attempt, then a clear failure")
        let seen = await model.seenPrompts.count
        XCTAssertEqual(seen, 2, "the model is called twice: original + one reduced retry")
    }

    private func longHistory() -> [Message] {
        var out: [Message] = []
        for i in 0..<8 {
            out.append(.user("old question \(i)"))
            out.append(.assistant(text: "", toolUses: [use("fat", i)]))
            out.append(.toolResults([ToolResult(toolUseId: "tfat\(i)", name: "fat", content: String(repeating: "B", count: 2000))]))
            out.append(.assistant("old answer \(i)"))
        }
        return out
    }
}
