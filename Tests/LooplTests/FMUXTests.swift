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

    // MARK: repeat breaker — identical consecutive calls only

    final class Counter: Tool, @unchecked Sendable {
        let name = "current_time"
        let description = "time"
        let parameters: JSONValue = ToolSchema.object(["timezone": ToolSchema.string("tz")])
        private let n = Mutex(0)
        var calls: Int { n.withLock { $0 } }
        func call(_ args: [String: JSONValue]) async throws -> String { n.withLock { $0 += 1 }; return "03:29" }
    }

    func testIdenticalCallInConsecutiveCyclesIsRefusedThenTheLoopEndsWithBestText() async throws {
        let use = ToolUse(toolUseId: "t1", name: "current_time", input: ["timezone": "Europe/Istanbul"])
        let again = ToolUse(toolUseId: "t2", name: "current_time", input: ["timezone": "Europe/Istanbul"])
        let third = ToolUse(toolUseId: "t3", name: "current_time", input: ["timezone": "Europe/Istanbul"])
        let tool = Counter()
        let model = FakeModel(turns: [.toolUse(text: "Let me check.", [use]), .toolUse([again]), .toolUse([third]), .text("never reached")])
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        var events: [AgentEvent] = []
        for try await e in agent.stream("what time is it in Istanbul?") { events.append(e) }

        XCTAssertEqual(tool.calls, 1, "executed once; the two verbatim repeats were refused")
        let results = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].status, .success)
        XCTAssertEqual(results[1].status, .error)
        XCTAssertTrue(results[1].content.contains("already called"), results[1].content)
        XCTAssertEqual(results[2].status, .error)
        let final = events.compactMap { if case .result(let r) = $0 { return r }; return nil }.first
        XCTAssertEqual(final?.stopReason, .endTurn)
        XCTAssertEqual(final?.text, "Let me check.", "the best text so far ends the turn")
        XCTAssertTrue(events.contains { if case .forceStop = $0 { return true }; return false })
        let prompts = await model.seenPrompts.count
        XCTAssertEqual(prompts, 3, "no fourth model call")
    }

    func testBestTextFallsBackToToolResultsWhenTheModelNeverSpoke() async throws {
        let use = ToolUse(toolUseId: "t1", name: "current_time", input: [:])
        let model = FakeModel(turns: [.toolUse([use]), .toolUse([ToolUse(toolUseId: "t2", name: "current_time", input: [:])]),
                                      .toolUse([ToolUse(toolUseId: "t3", name: "current_time", input: [:])])])
        let agent = Agent(model: model, tools: [Counter()], retryStrategy: nil)
        let r = try await agent("time?")
        XCTAssertEqual(r.text, "current_time: 03:29")
    }

    func testDifferentArgumentsAreNeverRefused() async throws {
        let tool = Counter()
        let zones = ["Europe/Istanbul", "Asia/Tokyo", "America/New_York", "Europe/Paris", "Australia/Sydney"]
        var turns: [FakeModel.Turn] = zones.enumerated().map { i, z in .toolUse([ToolUse(toolUseId: "t\(i)", name: "current_time", input: ["timezone": .string(z)])]) }
        turns.append(.text("done"))
        let agent = Agent(model: FakeModel(turns: turns), tools: [tool], retryStrategy: nil)
        let r = try await agent("times?")
        XCTAssertEqual(tool.calls, 5, "five different calls over five cycles — no cap, no refusal")
        XCTAssertEqual(r.text, "done")
    }

    func testRepeatAfterAGapIsNotConsecutiveAndRuns() async throws {
        let tool = Counter()
        let a = { (id: String) in ToolUse(toolUseId: id, name: "current_time", input: ["timezone": "Europe/Istanbul"]) }
        let b = ToolUse(toolUseId: "b", name: "current_time", input: ["timezone": "Asia/Tokyo"])
        let agent = Agent(model: FakeModel(turns: [.toolUse([a("1")]), .toolUse([b]), .toolUse([a("2")]), .text("ok")]), tools: [tool], retryStrategy: nil)
        _ = try await agent("x")
        XCTAssertEqual(tool.calls, 3, "only *consecutive* identical calls are refused")
    }

    func testBreakerResetsPerInvocation() async throws {
        let tool = Counter()
        let a = { (id: String) in ToolUse(toolUseId: id, name: "current_time", input: [:]) }
        let agent = Agent(model: FakeModel(turns: [.toolUse([a("1")]), .text("one"), .toolUse([a("2")]), .text("two")]), tools: [tool], retryStrategy: nil)
        _ = try await agent("x"); _ = try await agent("y")
        XCTAssertEqual(tool.calls, 2, "a new question may ask the same thing again")
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
