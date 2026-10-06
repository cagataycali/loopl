import XCTest
import Synchronization
@testable import Loopl

/// LOOPL-FM-UX: the three owner-reported Apple Intelligence bugs, at the SDK layer.
final class FMUXTests: XCTestCase {

    // MARK: gate releases held text that is clearly not a tool call

    private func stream(_ text: String, chunk: Int = 7) -> (live: String, final: String, events: [StreamEvent]) {
        var gate = ToolCallStreamGate(family: .generic)
        var live = ""
        var all: [StreamEvent] = []
        for p in text.chunked(chunk) {
            let evs = gate.feed(p); all += evs
            for e in evs { if case .contentBlockDelta(.text(let t)) = e { live += t } }
        }
        let fin = gate.finish(); all += fin
        var final = live
        for e in fin { if case .contentBlockDelta(.text(let t)) = e { final += t } }
        return (live, final, all)
    }

    func testFencedStatusMessageObjectIsReleasedAsTextWhileStreaming() {
        let answer = "```json\n{\"status\": \"completed\", \"message\": \"The current time in Istanbul is 6 October 2026 at 05:02, a quiet early morning in the city on the Bosphorus with the first ferries about to leave.\"}\n```"
        let r = stream(answer)
        XCTAssertFalse(r.live.isEmpty, "the JSON wrapper must stream live once it is clearly not a call")
        XCTAssertTrue(r.live.contains("\"message\""))
        XCTAssertTrue(r.final.contains("Bosphorus"))
        XCTAssertFalse(r.events.contains { if case .contentBlockStart(.toolUse) = $0 { return true }; return false })
        XCTAssertTrue(r.events.contains { if case .messageStop(.endTurn) = $0 { return true }; return false })
    }

    func testCodeFenceStreamsLive() {
        let answer = "Here you go:\n```swift\nlet x = 23 * 47\nprint(x)\n```\nThat prints 1081."
        let r = stream(answer, chunk: 5)
        XCTAssertTrue(r.live.contains("let x = 23 * 47"), "a ```swift block is code, not a tool call — it must stream: \(r.live)")
        XCTAssertTrue(r.live.contains("That prints 1081."), "text after the released fence streams too")
        XCTAssertEqual(r.final, answer)
    }

    func testProseInsideAFenceStreams() {
        let answer = "```\nJust a quoted paragraph the model decided to fence.\n```"
        let r = stream(answer)
        XCTAssertTrue(r.live.contains("quoted paragraph"))
    }

    func testFencedToolCallIsStillHeldAndParsed() {
        let call = "```json\n{\"name\": \"current_time\", \"arguments\": {\"timezone\": \"Europe/Istanbul\"}}\n```"
        let r = stream(call)
        XCTAssertEqual(r.live, "", "a real call never leaks as text")
        XCTAssertTrue(r.events.contains { if case .contentBlockStart(.toolUse(_, "current_time")) = $0 { return true }; return false })
        XCTAssertTrue(r.events.contains { if case .messageStop(.toolUse) = $0 { return true }; return false })
    }

    func testPrettyPrintedToolCallWithNameLaterIsStillHeld() {
        let call = "```json\n{\n  \"arguments\": {\"timezone\": \"Europe/Istanbul\"},\n  \"name\": \"current_time\"\n}\n```"
        let r = stream(call, chunk: 3)
        XCTAssertEqual(r.live, "")
        XCTAssertTrue(r.events.contains { if case .contentBlockStart(.toolUse(_, "current_time")) = $0 { return true }; return false })
    }

    func testLongFencedJSONWithoutNameIsReleasedAtTheLimit() {
        let body = "{\"status\": \"ok\", \"items\": [" + (0..<60).map { "\"item \($0)\"" }.joined(separator: ", ") + "]}"
        var gate = ToolCallStreamGate(family: .generic)
        var liveAt: Int?
        var fed = 0
        for p in ("```json\n" + body + "\n```").chunked(10) {
            fed += p.count
            for e in gate.feed(p) { if case .contentBlockDelta(.text) = e, liveAt == nil { liveAt = fed } }
        }
        XCTAssertNotNil(liveAt)
        XCTAssertLessThan(liveAt!, 8 + ToolCallStreamGate.heldJSONLimit + 20, "released around the limit, not at finish")
    }

    // MARK: textReplace through the assembler and the transcript

    func testAssemblerAndTranscriptHonourTextReplace() {
        var a = StreamAssembler()
        var ui: [StreamAssembler.Event] = []
        for e in [StreamEvent.messageStart(role: .assistant), .contentBlockStart(.text), .contentBlockDelta(.text("Hello wor")),
                  .contentBlockDelta(.textReplace("Hello, world!")), .contentBlockStop, .messageStop(.endTurn)] { ui += a.feed(e) }
        let stop = a.finish()
        XCTAssertEqual(stop.message.text, "Hello, world!")
        XCTAssertTrue(ui.contains { if case .textReplace("Hello, world!") = $0 { return true }; return false })

        var t = Transcript()
        t.user("hey")
        t.apply(.startEventLoop(cycle: 1))
        t.apply(.text("Hello wor"))
        t.apply(.textReplace("Hello, world!"))
        XCTAssertEqual(t.items.last?.kind, .assistant("Hello, world!"))
        t.apply(.modelMessage(.assistant("Hello, world!")))
        XCTAssertEqual(t.items.filter { if case .assistant = $0.kind { return true }; return false }.count, 1, "replace never duplicates the row")
    }

    // MARK: redundancy filter

    struct MirrorTool: Tool {
        let name = "apple_intelligence"
        let description = "wraps the FM runtime"
        let parameters: JSONValue = ToolSchema.object(["text": ToolSchema.string("t")], required: ["text"])
        var redundantWithRuntime: RuntimeKind? { .appleFM }
        func call(_ args: [String: JSONValue]) async throws -> String { "mirror" }
    }
    actor FMKindModel: Model {
        nonisolated let kind: RuntimeKind = .appleFM
        var loadedModelId: String? = "fm"
        var params = GenerationParams()
        nonisolated static func availability() -> RuntimeAvailability { .ok }
        func updateConfig(_ params: GenerationParams) {}
        func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {}
        func unload() async {}
        let inner = FakeModel(turns: [.text("hi there")])
        nonisolated func stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
            inner.stream(messages, toolSpecs: toolSpecs, systemPrompt: systemPrompt)
        }
        func seenSpecs() async -> [[ToolSpec]] { await inner.seenToolSpecs }
    }

    func testToolRedundantWithTheActiveRuntimeIsNotOffered() async throws {
        let model = FMKindModel()
        let agent = Agent(model: model, tools: [MirrorTool(), CalculatorTool()], retryStrategy: nil)
        let offered = await agent.offeredTools.map(\.name)
        XCTAssertEqual(offered, ["calculator"])
        let withheld = await agent.withheldTools
        XCTAssertEqual(withheld.map(\.name), ["apple_intelligence"])
        XCTAssertEqual(withheld.first?.runtime, .appleFM)
        _ = try await agent("hey")
        let specs = await model.seenSpecs()
        XCTAssertEqual(specs.first?.map(\.name), ["calculator"], "the model never sees its own mirror")

        // The same tool IS offered to any other runtime.
        let mlx = Agent(model: FakeModel(turns: [.text("x")]), tools: [MirrorTool()], retryStrategy: nil)
        let mlxOffered = await mlx.offeredTools.map(\.name)
        XCTAssertEqual(mlxOffered, ["apple_intelligence"])
    }

    // MARK: no repeat heuristics — every call the model makes is run (faithful Strands)

    final class Counter: Tool, @unchecked Sendable {
        let name = "current_time"
        let description = "time"
        let parameters: JSONValue = ToolSchema.object(["timezone": ToolSchema.string("tz")])
        private let n = Mutex(0)
        var calls: Int { n.withLock { $0 } }
        func call(_ args: [String: JSONValue]) async throws -> String { n.withLock { $0 += 1 }; return "03:29" }
    }

    /// OWNER DECISION 2026-10-06: no RepeatBreaker, no repeat guard. The same call in
    /// consecutive cycles is executed each time and the model sees each honest result;
    /// stopping, or changing the arguments, is the model's decision — never a heuristic's.
    func testIdenticalCallsInConsecutiveCyclesAreExecutedEveryTime() async throws {
        let use = ToolUse(toolUseId: "t1", name: "current_time", input: ["timezone": "Europe/Istanbul"])
        let again = ToolUse(toolUseId: "t2", name: "current_time", input: ["timezone": "Europe/Istanbul"])
        let third = ToolUse(toolUseId: "t3", name: "current_time", input: ["timezone": "Europe/Istanbul"])
        let tool = Counter()
        let model = FakeModel(turns: [.toolUse(text: "Let me check.", [use]), .toolUse([again]), .toolUse([third]), .text("It is 03:29 in Istanbul.")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        var events: [AgentEvent] = []
        for try await e in agent.stream("what time is it in Istanbul?") { events.append(e) }

        XCTAssertEqual(tool.calls, 3, "every call runs — there is no repeat heuristic")
        let results = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.status == .success && $0.content == "03:29" })
        let final = events.compactMap { if case .result(let r) = $0 { return r }; return nil }.first
        XCTAssertEqual(final?.stopReason, .endTurn)
        XCTAssertEqual(final?.text, "It is 03:29 in Istanbul.")
        XCTAssertFalse(events.contains { if case .forceStop = $0 { return true }; return false }, "nothing forces the loop to stop")
        let prompts = await model.seenPrompts.count
        XCTAssertEqual(prompts, 4, "the model is asked after every result")
    }

    func testDifferentArgumentsOverManyCyclesAllRun() async throws {
        let tool = Counter()
        let zones = ["Europe/Istanbul", "Asia/Tokyo", "America/New_York", "Europe/Paris", "Australia/Sydney"]
        var turns: [FakeModel.Turn] = zones.enumerated().map { i, z in .toolUse([ToolUse(toolUseId: "t\(i)", name: "current_time", input: ["timezone": .string(z)])]) }
        turns.append(.text("done"))
        let agent = Agent(model: FakeModel(turns: turns), tools: [tool], retryStrategy: nil)
        let r = try await agent("times?")
        XCTAssertEqual(tool.calls, 5, "five calls over five cycles — no cap, no refusal")
        XCTAssertEqual(r.text, "done")
    }

    /// An errored call retried verbatim is the model reading the error and trying again —
    /// exactly the behaviour the owner wants the loop to leave to the model.
    func testIdenticalCallAfterAnErrorIsRetried() async throws {
        final class Flaky: Tool, @unchecked Sendable {
            let name = "http"; let description = "h"; let parameters: JSONValue = ToolSchema.object([:])
            private let n = Mutex(0)
            var calls: Int { n.withLock { $0 } }
            func call(_ args: [String: JSONValue]) async throws -> String {
                let c = n.withLock { $0 += 1; return $0 }
                if c == 1 { throw ToolError("timeout") }
                return "ok"
            }
        }
        let tool = Flaky()
        let a = { (id: String) in ToolUse(toolUseId: id, name: "http", input: ["url": "https://x"]) }
        let agent = Agent(model: FakeModel(turns: [.toolUse([a("1")]), .toolUse([a("2")]), .text("done")]), tools: [tool], retryStrategy: nil)
        var events: [AgentEvent] = []
        for try await e in agent.stream("fetch") { events.append(e) }
        let results = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }
        XCTAssertEqual(tool.calls, 2)
        XCTAssertEqual(results.map(\.status), [.error, .success], "the model saw the honest error before retrying")
        XCTAssertTrue(results[0].content.contains("timeout"), results[0].content)
        let final = events.compactMap { if case .result(let r) = $0 { return r }; return nil }.first
        XCTAssertEqual(final?.text, "done")
    }

    // MARK: lone string argument

    func testLoneStringArgumentIsLiftedIntoTheOnlyRequiredKey() {
        let parsed = ToolCallParser(family: .generic).parse("```json\n{\"name\": \"calculator\", \"arguments\": \"23*47\"}\n```")
        XCTAssertEqual(parsed.calls.first?.input, ["_": "23*47"])
        let outcome = ToolValidation.validateAndPrepare(toolUses: parsed.calls, tools: [CalculatorTool()])
        XCTAssertEqual(outcome.valid.first?.input, ["expression": "23*47"])
        XCTAssertTrue(outcome.results.isEmpty)
    }
}

private extension String {
    func chunked(_ size: Int) -> [String] {
        var out: [String] = []; var i = startIndex
        while i < endIndex { let j = index(i, offsetBy: size, limitedBy: endIndex) ?? endIndex; out.append(String(self[i..<j])); i = j }
        return out
    }
}
