import XCTest
@testable import loopl

final class AgentLoopTests: XCTestCase {
    func testToolCallThenAnswer() async throws {
        let rt = FakeRuntime(scripts: [
            "<tool_call>{\"name\": \"calculator\", \"arguments\": {\"expression\": \"23*47\"}}</tool_call>",
            "23 × 47 is 1081.",
        ])
        var events: [AgentEvent] = []
        for try await e in AgentLoop.run(messages: [.system("s"), .user("23*47?")], runtime: rt, tools: [CalculatorTool()], config: AgentConfig()) {
            events.append(e)
        }
        let toolResults = events.compactMap { if case .toolFinished(_, let n, let r, _, let err) = $0 { return (n, r, err) }; return nil }
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(toolResults[0].0, "calculator")
        XCTAssertEqual(toolResults[0].1, "23*47 = 1081")
        XCTAssertFalse(toolResults[0].2)
        guard case .finished(let n, let reason)? = events.last else { return XCTFail("no finish") }
        XCTAssertEqual(n, 2); XCTAssertEqual(reason, .answered)

        // The second prompt must carry assistant(toolCalls) + tool(result).
        let prompts = await rt.seenPrompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts[1].count, 4)
        XCTAssertEqual(prompts[1][2].toolCalls.first?.name, "calculator")
        if case .tool(let result, let callId, let name) = prompts[1][3] {
            XCTAssertEqual(result, "23*47 = 1081"); XCTAssertEqual(name, "calculator"); XCTAssertEqual(callId, prompts[1][2].toolCalls.first?.id)
        } else { XCTFail("4th message should be the tool result") }
        let texts = events.compactMap { if case .token(let t) = $0 { return t }; return nil }.joined()
        XCTAssertTrue(texts.contains("1081"))
    }

    func testUnknownToolIsReportedAndLoopContinues() async throws {
        let rt = FakeRuntime(scripts: ["<tool_call>{\"name\": \"nope\", \"arguments\": {}}</tool_call>", "ok"])
        var errors = 0
        for try await e in AgentLoop.run(messages: [.user("x")], runtime: rt, tools: [CalculatorTool()], config: AgentConfig()) {
            if case .toolFinished(_, _, let r, _, let err) = e { XCTAssertTrue(err); XCTAssertTrue(r.contains("unknown tool")); errors += 1 }
        }
        XCTAssertEqual(errors, 1)
    }

    func testMaxIterationsStopsTheLoop() async throws {
        let rt = FakeRuntime(scripts: Array(repeating: "<tool_call>{\"name\": \"calculator\", \"arguments\": {\"expression\": \"1+1\"}}</tool_call>", count: 20))
        var cfg = AgentConfig(); cfg.maxIterations = 3
        var last: AgentEvent?
        for try await e in AgentLoop.run(messages: [.user("loop")], runtime: rt, tools: [CalculatorTool()], config: cfg) { last = e }
        guard case .finished(let n, let reason)? = last else { return XCTFail() }
        XCTAssertEqual(n, 3); XCTAssertEqual(reason, .maxIterations)
    }

    func testCancellation() async throws {
        let rt = FakeRuntime(scripts: [String(repeating: "word ", count: 2000)], delayPerChunkNs: 2_000_000)
        let stream = AgentLoop.run(messages: [.user("x")], runtime: rt, tools: [], config: AgentConfig())
        let task = Task { () -> Int in
            var n = 0
            for try await e in stream { if case .token = e { n += 1 } }
            return n
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let n = try await task.value
        XCTAssertLessThan(n, 2000)
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
