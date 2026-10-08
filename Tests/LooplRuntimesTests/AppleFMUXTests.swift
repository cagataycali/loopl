import XCTest
import Synchronization
import Loopl
@testable import LooplRuntimes

/// LOOPL-FM-UX at the runtime layer: the JSON-wrapper answer, live snapshots, the FM prompt.
final class AppleFMUXTests: XCTestCase {

    // MARK: unwrap — the owner's exact shape

    func testUnwrapsStatusMessageObject() {
        XCTAssertEqual(AppleFMAnswer.unwrap(#"{"status":"completed","message":"The current time in Istanbul is 05:02."}"#),
                       "The current time in Istanbul is 05:02.")
        XCTAssertEqual(AppleFMAnswer.unwrap("```json\n{\n  \"status\": \"completed\",\n  \"message\": \"Hello! How can I help you today?\"\n}\n```"),
                       "Hello! How can I help you today?")
        XCTAssertEqual(AppleFMAnswer.unwrap(#"{"answer": "1081"}"#), "1081")
        XCTAssertEqual(AppleFMAnswer.unwrap(#"{"response": "ok", "message": "first by preference"}"#), "first by preference")
    }

    func testUnwrapLeavesEverythingElseAlone() {
        XCTAssertNil(AppleFMAnswer.unwrap("Plain prose."))
        XCTAssertNil(AppleFMAnswer.unwrap(#"{"name": "current_time", "arguments": {}}"#), "a call is the parser's business")
        XCTAssertNil(AppleFMAnswer.unwrap(#"{"status": "completed"}"#), "nothing to show → keep the text")
        XCTAssertNil(AppleFMAnswer.unwrap(#"{"message": ""}"#))
        XCTAssertNil(AppleFMAnswer.unwrap(#"[{"message": "a list is data the user may have asked for"}]"#))
        XCTAssertNil(AppleFMAnswer.unwrap("```swift\nlet x = 1\n```"))
    }

    // MARK: through the runtime

    /// Snapshots scripted exactly, so non-monotonic revisions can be simulated.
    final class SnapshotFactory: AppleFMSessionFactory, Sendable {
        let availability = RuntimeAvailability.ok
        private let scripts: Mutex<[[String]]>
        init(_ scripts: [[String]]) { self.scripts = Mutex(scripts) }
        func makeSession(instructions: String?, temperature: Double, maxTokens: Int?) throws -> any AppleFMSession {
            let s = scripts.withLock { $0.isEmpty ? [] : $0.removeFirst() }
            return SnapshotSession(snaps: s)
        }
    }
    struct SnapshotSession: AppleFMSession {
        let snaps: [String]
        func snapshots(prompt: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { c in for s in snaps { c.yield(s) }; c.finish() }
        }
    }

    private func collect(_ scripts: [[String]], tools: [any Tool] = [CalculatorTool()], prompt: String = "hey") async throws -> (events: [AgentEvent], result: AgentResult) {
        let model = AppleFoundationModel(sessionFactory: SnapshotFactory(scripts))
        let agent = Agent(model: model, tools: tools, retryStrategy: nil)
        var events: [AgentEvent] = []
        for try await e in agent.stream(prompt) { events.append(e) }
        let result = events.compactMap { if case .result(let r) = $0 { return r }; return nil }.first!
        return (events, result)
    }

    func testJSONWrapperAnswerBecomesProseAndStreamedLive() async throws {
        let json = #"{"status": "completed", "message": "Hello! How can I help you today?"}"#
        let snaps = stride(from: 8, through: json.count, by: 8).map { String(json.prefix($0)) } + [json]
        let (events, result) = try await collect([snaps])
        XCTAssertEqual(result.text, "Hello! How can I help you today?")
        XCTAssertEqual(result.stopReason, .endTurn)
        let liveText = events.compactMap { if case .text(let t) = $0 { return t }; return nil }
        XCTAssertGreaterThanOrEqual(liveText.count, 3, "the bare JSON streamed live before being unwrapped: \(liveText)")
        XCTAssertTrue(events.contains { if case .textReplace("Hello! How can I help you today?") = $0 { return true }; return false })
        // What the UI ends with
        var t = Transcript(); t.user("hey")
        for e in events { t.apply(e) }
        XCTAssertEqual(t.items.filter { if case .assistant = $0.kind { return true }; return false }.map(\.kind), [.assistant("Hello! How can I help you today?")])
    }

    func testFencedJSONWrapperAnswerBecomesProse() async throws {
        let fenced = "```json\n{\"status\": \"completed\", \"message\": \"It is 05:02 in Istanbul.\"}\n```"
        let (_, result) = try await collect([[String(fenced.prefix(12)), String(fenced.prefix(40)), fenced]])
        XCTAssertEqual(result.text, "It is 05:02 in Istanbul.")
    }

    func testNonMonotonicSnapshotsReplaceTheTextInsteadOfDroppingIt() async throws {
        // FM revised "Hello wor" into "Hello, world! Nice to meet you."
        let (events, result) = try await collect([["Hello", "Hello wor", "Hello, world!", "Hello, world! Nice to meet you."]])
        XCTAssertEqual(result.text, "Hello, world! Nice to meet you.")
        let replaces = events.compactMap { if case .textReplace(let s) = $0 { return s }; return nil }
        XCTAssertEqual(replaces, ["Hello, world!"], "the revision arrives as one replace, not a dropped snapshot")
        let live = events.compactMap { if case .text(let t) = $0 { return t }; return nil }
        XCTAssertEqual(live.joined(), "Hello wor" + " Nice to meet you.", "deltas before and after the revision")
        var t = Transcript(); t.user("hey")
        for e in events { t.apply(e) }
        XCTAssertEqual(t.items.last?.kind, .assistant("Hello, world! Nice to meet you."))
        XCTAssertEqual(t.items.filter { if case .assistant = $0.kind { return true }; return false }.count, 1)
    }

    func testPlainProseStreamsAsSnapshotsArrive() async throws {
        let (events, result) = try await collect([["Hey", "Hey there!", "Hey there! How can", "Hey there! How can I help?"]])
        XCTAssertEqual(result.text, "Hey there! How can I help?")
        let live = events.compactMap { if case .text(let t) = $0 { return t }; return nil }
        XCTAssertEqual(live.count, 4, "every snapshot reaches the UI as it arrives: \(live)")
        let metrics = events.compactMap { if case .metrics(let m) = $0 { return m }; return nil }
        XCTAssertTrue(metrics.contains { $0.ttftMs > 0 }, "TTFT still measured")
        XCTAssertTrue(metrics.last.map { $0.generatedTokens > 0 } ?? false)
    }

    // MARK: pseudo-call recovery

    func testPseudoCallDetection() {
        let names = ["current_time", "calculator"]
        XCTAssertEqual(AppleFMPrompt.pseudoCall(in: "current_time(\"Europe/Istanbul\")", toolNames: names), "current_time")
        XCTAssertEqual(AppleFMPrompt.pseudoCall(in: "current_time \"Europe/Istanbul\"\n", toolNames: names), "current_time")
        XCTAssertEqual(AppleFMPrompt.pseudoCall(in: "calculator: 23*47", toolNames: names), "calculator")
        XCTAssertEqual(AppleFMPrompt.pseudoCall(in: "current_time -- timezone=Europe/Istanbul", toolNames: names), "current_time")
        XCTAssertNil(AppleFMPrompt.pseudoCall(in: "The current_time tool tells the time.", toolNames: names))
        XCTAssertNil(AppleFMPrompt.pseudoCall(in: "current_time is a tool you can use", toolNames: names))
        XCTAssertNil(AppleFMPrompt.pseudoCall(in: "Hello! How can I help?", toolNames: names))
        XCTAssertNil(AppleFMPrompt.pseudoCall(in: "current_time(\"x\")\nand more lines", toolNames: names))
    }

    func testPseudoCallIsReaskedOnceAndTheTextReplaced() async throws {
        let call = "```json\n{\"name\": \"current_time\", \"arguments\": {\"timezone\": \"Europe/Istanbul\"}}\n```"
        let time = ClosureTool(name: "current_time", description: "time", parameters: ToolSchema.object(["timezone": ToolSchema.string("tz")])) { _ in "05:02" }
        // 1) pseudo-call as text  2) the real call once insisted  3) the answer
        let (events, result) = try await collect([["current_time(\"Europe/Istanbul\")"], [call], ["It is 05:02 in Istanbul."]], tools: [time], prompt: "what time is it in Istanbul?")
        XCTAssertEqual(result.text, "It is 05:02 in Istanbul.")
        let toolCalls = events.filter { if case .toolStarted = $0 { return true }; return false }.count
        XCTAssertEqual(toolCalls, 1)
        XCTAssertTrue(events.contains { if case .textReplace("") = $0 { return true }; return false }, "the streamed pseudo-call is wiped from the UI")
        var t = Transcript(); t.user("q")
        for e in events { t.apply(e) }
        let assistantTexts = t.items.compactMap { if case .assistant(let s) = $0.kind { return s }; return nil }
        XCTAssertEqual(assistantTexts, ["It is 05:02 in Istanbul."], "no pseudo-call row survives")
    }

    func testPseudoCallReaskHappensOnlyOnce() async throws {
        let time = ClosureTool(name: "current_time", description: "time") { _ in "05:02" }
        let (_, result) = try await collect([["current_time(\"Europe/Istanbul\")"], ["current_time(\"Europe/Istanbul\")"]], tools: [time], prompt: "time?")
        XCTAssertEqual(result.text, "current_time(\"Europe/Istanbul\")", "second time it stands as text — no endless re-asking")
    }

    // MARK: prompt wording

    func testFMPromptAnswersDirectlyBeforeOfferingToolsAndForbidsJSONAnswers() {
        let built = AppleFMPrompt.build(messages: [.user("hey")], toolSpecs: [CalculatorTool().toolSpec, CurrentTimeTool().toolSpec], systemPrompt: "Be brief.")
        let i = built.instructions
        XCTAssertTrue(i.hasPrefix("Be brief."))
        let direct = i.range(of: "Answer the user directly in plain text")!
        let tools = i.range(of: "Tools you may call ONLY when")!
        XCTAssertLessThan(direct.lowerBound, tools.lowerBound, "answer-directly comes before the tool list")
        XCTAssertTrue(i.contains("Never answer in JSON."))
        XCTAssertTrue(i.contains("Never invent a tool name."))
        XCTAssertFalse(i.contains("\"type\": \"function\""), "no raw JSON schema in instructions (tokengeneration Code=10)")
        XCTAssertEqual(built.prompt, "hey")
        XCTAssertEqual(built.mode, .call)
    }

    // MARK: the real model, when this machine has one

    /// "hey" → prose with no tool call; a time question → exactly one `current_time` call, a prose
    /// answer, no JSON. Skipped where Apple Intelligence is unavailable (CI, simulator).
    func testLiveFMGreetsInProseAndCallsOneToolForTime() async throws {
        let availability = AppleFoundationModel.availability()
        try XCTSkipUnless(availability.available, "Apple Intelligence unavailable: \(availability.reason)")
        let time = ClosureTool(name: "current_time", description: "Current date and time, optionally in a given IANA timezone.",
                               parameters: ToolSchema.object(["timezone": ToolSchema.string("IANA timezone, e.g. Europe/Istanbul")])) { _ in
            #"{"iso":"2026-10-06T05:02:11+03:00","timezone":"Europe/Istanbul","pretty":"6 October 2026 at 05:02"}"#
        }
        let mirror = ClosureTool(name: "apple_intelligence", description: "Ask Apple's on-device model to summarize text") { _ in "never" }
        let agent = Agent(model: AppleFoundationModel(), tools: [time, CalculatorTool(), mirror], systemPrompt: "You are loopl, a helpful on-device assistant.", retryStrategy: nil)

        let hey = try await agent("hey")
        XCTAssertEqual(hey.stopReason, .endTurn)
        let heyCalls = await agent.eventLoopMetrics.toolCallCount
        XCTAssertEqual(heyCalls, 0, "a greeting needs no tool: \(hey.text)")
        XCTAssertFalse(hey.text.contains("{"), "prose, not JSON: \(hey.text)")
        XCTAssertFalse(hey.text.isEmpty)

        await agent.reset()
        var textEvents = 0
        var answer = ""
        for try await e in agent.stream("what time is it in Istanbul?") {
            if case .text = e { textEvents += 1 }
            if case .result(let r) = e { answer = r.text }
        }
        let timeCalls = await agent.eventLoopMetrics.toolCallCount
        XCTAssertEqual(timeCalls, 1, "exactly one tool call")
        XCTAssertFalse(answer.contains("\"name\"") || answer.hasPrefix("{"), "the answer must be prose: \(answer)")
        XCTAssertTrue(answer.contains("5:02") || answer.lowercased().contains("october"), "uses the tool result: \(answer)")
        XCTAssertGreaterThanOrEqual(textEvents, 1)
    }
}
