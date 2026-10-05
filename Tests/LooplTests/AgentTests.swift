import XCTest
import Loopl

final class AgentTests: XCTestCase {
    func call(_ name: String, _ args: [String: JSONValue] = [:]) -> String {
        "<tool_call>{\"name\": \"\(name)\", \"arguments\": \(JSONValue.object(args).compact)}</tool_call>"
    }

    func testToolCallThenAnswer() async throws {
        let model = FakeModel(scripts: [call("calculator", ["expression": "23*47"]), "23 × 47 is 1081."])
        let agent = Agent(model: model, tools: [CalculatorTool()], systemPrompt: "s")
        var events: [AgentEvent] = []
        for try await e in agent.stream("23*47?") { events.append(e) }
        let results = events.compactMap { if case .toolFinished(let r) = $0 { return r }; return nil }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "calculator")
        XCTAssertEqual(results[0].content, "23*47 = 1081")
        XCTAssertFalse(results[0].isError)
        guard case .finished(let n, let reason)? = events.last else { return XCTFail("no finish") }
        XCTAssertEqual(n, 2); XCTAssertEqual(reason, .answered)

        // The second prompt must carry system, user, assistant(toolCalls), tool(result).
        let prompts = await model.seenPrompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts[1].map(\.role), ["system", "user", "assistant", "tool"])
        XCTAssertEqual(prompts[1][2].toolCalls.first?.name, "calculator")
        if case .tool(let result, let callId, let name) = prompts[1][3] {
            XCTAssertEqual(result, "23*47 = 1081"); XCTAssertEqual(name, "calculator"); XCTAssertEqual(callId, prompts[1][2].toolCalls.first?.id)
        } else { XCTFail("4th message should be the tool result") }
        XCTAssertTrue(events.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined().contains("1081"))
        // History is kept on the agent (Strands: agent.messages).
        let history = await agent.messages
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history.last?.text, "23 × 47 is 1081.")
    }

    func testCallAsFunctionReturnsResult() async throws {
        let model = FakeModel(scripts: [call("calculator", ["expression": "2+2"]), "4"])
        let agent = Agent(model: model, tools: [CalculatorTool()])
        let r = try await agent("2+2?")
        XCTAssertEqual(r.text, "4"); XCTAssertEqual(r.iterations, 2); XCTAssertEqual(r.toolResults.count, 1); XCTAssertEqual(r.reason, .answered)
    }

    func testUnknownToolIsReportedAndLoopContinues() async throws {
        let model = FakeModel(scripts: [call("nope"), "ok"])
        var errors = 0
        for try await e in Agent(model: model, tools: [CalculatorTool()]).stream("x") {
            if case .toolFinished(let r) = e { XCTAssertTrue(r.isError); XCTAssertTrue(r.content.contains("unknown tool")); errors += 1 }
        }
        XCTAssertEqual(errors, 1)
    }

    func testTwentyDeepRecursionIsUnlimitedByDefault() async throws {
        var scripts: [String] = []
        for i in 1...20 { scripts.append(call("calculator", ["expression": .string("\(i)+1")])) }
        scripts.append("done after twenty")
        let model = FakeModel(scripts: scripts)
        let agent = Agent(model: model, tools: [CalculatorTool()])
        let r = try await agent("count")
        XCTAssertEqual(r.iterations, 21)
        XCTAssertEqual(r.toolResults.count, 20)
        XCTAssertEqual(r.text, "done after twenty")
        XCTAssertEqual(r.reason, .answered)
    }

    func testBudgetCapsIterations() async throws {
        let model = FakeModel(scripts: Array(repeating: call("calculator", ["expression": "1+1"]), count: 20))
        var cfg = AgentConfig(); cfg.budget = Budget(maxIterations: 3); cfg.loopDetector = nil
        var events: [AgentEvent] = []
        for try await e in Agent(model: model, tools: [CalculatorTool()], config: cfg).stream("loop") { events.append(e) }
        guard case .finished(let n, let reason)? = events.last else { return XCTFail() }
        XCTAssertEqual(n, 3); XCTAssertEqual(reason, .budget)
        XCTAssertTrue(events.contains { if case .warning(let w) = $0 { return w.contains("max iterations") }; return false })
    }

    func testLoopDetectorWarnsButNeverStops() async throws {
        let model = FakeModel(scripts: Array(repeating: call("calculator", ["expression": "1+1"]), count: 5) + ["ok"])
        var warnings = 0
        var finished: FinishReason?
        for try await e in Agent(model: model, tools: [CalculatorTool()]).stream("x") {
            if case .warning = e { warnings += 1 }
            if case .finished(_, let r) = e { finished = r }
        }
        XCTAssertEqual(warnings, 3)            // 3rd, 4th and 5th identical calls
        XCTAssertEqual(finished, .answered)    // it still ran to the model's own answer
    }

    func testCancellation() async throws {
        let model = FakeModel(scripts: [String(repeating: "word ", count: 2000)], delayPerChunkNs: 2_000_000)
        let stream = Agent(model: model).stream("x")
        let task = Task { () -> Int in
            var n = 0
            for try await e in stream { if case .text = e { n += 1 } }
            return n
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let n = try await task.value
        XCTAssertLessThan(n, 2000)
    }

    func testTranscriptFold() async throws {
        let model = FakeModel(scripts: [call("calculator", ["expression": "23*47"]), "1081"])
        var t = Transcript()
        t.user("q")
        for try await e in Agent(model: model, tools: [CalculatorTool()]).stream("q") { t.apply(e) }
        XCTAssertFalse(t.isRunning)
        XCTAssertEqual(t.iteration, 2)
        // user, tool card (the empty assistant turn was removed), final assistant text
        XCTAssertEqual(t.items.count, 3)
        guard case .toolCall(let c, let r?) = t.items[1].kind else { return XCTFail("expected tool card") }
        XCTAssertEqual(c.name, "calculator"); XCTAssertEqual(r.content, "23*47 = 1081")
        XCTAssertEqual(t.items[2].kind, .assistant("1081"))
    }
}

final class ToolsTests: XCTestCase {
    func testCalculator() throws {
        XCTAssertEqual(try Calculator.evaluate("23*47"), 1081)
        XCTAssertEqual(try Calculator.evaluate("2^10"), 1024)
        XCTAssertEqual(try Calculator.evaluate("-(3+4)*2"), -14)
        XCTAssertEqual(try Calculator.evaluate("sqrt(16) + max(1, 5, 3)"), 9)
        XCTAssertEqual(try Calculator.evaluate("10 % 4"), 2)
        XCTAssertEqual(try Calculator.evaluate("2^3^2"), 512)
        XCTAssertEqual(Calculator.format(try Calculator.evaluate("1/3")), "0.3333333333")
        XCTAssertThrowsError(try Calculator.evaluate("1/0"))
        XCTAssertThrowsError(try Calculator.evaluate("FUNCTION(1)"))
        XCTAssertThrowsError(try Calculator.evaluate("self.foo"))
        XCTAssertThrowsError(try Calculator.evaluate("2 +"))
    }

    func testCurrentTimeIstanbul() async throws {
        let out = try await CurrentTimeTool().call(["timezone": "Europe/Istanbul"])
        XCTAssertTrue(out.contains("Europe/Istanbul"))
        let city = try await CurrentTimeTool().call(["timezone": "Istanbul"])
        XCTAssertTrue(city.contains("Europe/Istanbul"))
    }

    func testHttpGetRefusedOffline() async {
        let was = NetworkPolicy.isOffline
        NetworkPolicy.setOffline(true); defer { NetworkPolicy.setOffline(was) }
        do { _ = try await HttpGetTool().call(["url": "https://example.com"]); XCTFail("should refuse") }
        catch { XCTAssertTrue(error.localizedDescription.contains("offline")) }
    }

    func testDownloaderRefusesOffline() async {
        let was = NetworkPolicy.isOffline
        NetworkPolicy.setOffline(true); defer { NetworkPolicy.setOffline(was) }
        do { _ = try await HFDownloader(token: nil).listFiles(repo: "mlx-community/Qwen3-0.6B-4bit"); XCTFail("should refuse") }
        catch { XCTAssertTrue(error.localizedDescription.contains("offline")) }
    }

    func testWantedFiles() {
        typealias F = HFDownloader.RemoteFile
        XCTAssertTrue(HFDownloader.wanted(F(path: "model.safetensors", size: 1, type: "file")))
        XCTAssertTrue(HFDownloader.wanted(F(path: "tokenizer.json", size: 1, type: "file")))
        XCTAssertFalse(HFDownloader.wanted(F(path: "README.md", size: 1, type: "file")))
        XCTAssertFalse(HFDownloader.wanted(F(path: "pytorch_model.bin", size: 1, type: "file")))
    }

    func testRememberRecall() async throws {
        _ = try await RememberTool().call(["key": "test-key", "value": "hello"])
        let r = try await RecallTool().call(["key": "test-key"])
        XCTAssertEqual(r, "test-key: hello")
    }
}
