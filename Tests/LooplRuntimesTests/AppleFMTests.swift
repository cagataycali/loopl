import XCTest
import Synchronization
@testable import Loopl
@testable import LooplRuntimes

/// Pins the P0 the owner found on his iPhone: with Apple Intelligence, one
/// question that needs one tool ran `current_time` TWICE and answered twice.
///
/// The replies scripted here are not invented — they are what the real
/// FoundationModels model produced on macOS 26.4.1 (2026-10-06) when it was
/// given loopl's prompts: a fenced call first, then, when the tool exchange was
/// fed back as `<tool_call>` / `<tool_response>` markup, *the identical call
/// again* (3 runs out of 3), and a plain-text answer once the round was
/// rendered as "tools have already been run for you".
final class AppleFMTests: XCTestCase {

    // MARK: - scripted session seam

    /// Replays canned responses in order, one per generation, recording the
    /// instructions + prompt it was handed.
    final class ScriptedFMFactory: AppleFMSessionFactory, Sendable {
        private struct State { var replies: [String]; var prompts: [(instructions: String?, prompt: String)] = [] }
        private let state: Mutex<State>
        let availability = RuntimeAvailability.ok

        init(_ replies: [String]) { state = Mutex(State(replies: replies)) }

        func makeSession(instructions: String?, temperature: Double, maxTokens: Int?) throws -> any AppleFMSession {
            let (reply, index) = state.withLock { s -> (String, Int) in
                let r = s.replies.isEmpty ? "" : s.replies.removeFirst()
                s.prompts.append((instructions, ""))
                return (r, s.prompts.count - 1)
            }
            return ScriptedFMSession(reply: reply) { [self] p in record(index, p) }
        }

        private func record(_ i: Int, _ prompt: String) { state.withLock { $0.prompts[i].prompt = prompt } }

        var promptCount: Int { state.withLock { $0.prompts.count } }
        func prompt(_ i: Int) -> (instructions: String?, prompt: String) { state.withLock { $0.prompts[i] } }
    }

    struct ScriptedFMSession: AppleFMSession {
        let reply: String
        let record: @Sendable (String) -> Void
        /// Yields cumulative snapshots, as `LanguageModelSession.streamResponse` does.
        func snapshots(prompt: String) -> AsyncThrowingStream<String, Error> {
            record(prompt)
            let reply = self.reply
            return AsyncThrowingStream { continuation in
                var sofar = ""
                for chunk in reply.chunked(8) { sofar += chunk; continuation.yield(sofar) }
                continuation.finish()
            }
        }
    }

    /// Counts its invocations — the whole point of the test.
    final class CountingTool: Tool {
        let name = "current_time"
        let description = "Current date and time, optionally in a given IANA timezone."
        let parameters = ToolSchema.object(["timezone": ToolSchema.string("IANA timezone, e.g. Europe/Istanbul")])
        private let counter = Mutex(0)
        var calls: Int { counter.withLock { $0 } }
        func call(_ args: [String: JSONValue]) async throws -> String {
            counter.withLock { $0 += 1 }
            return #"{"iso":"2026-10-06T03:29:02+03:00","timezone":"Europe/Istanbul","pretty":"6 October 2026 at 03:29"}"#
        }
    }

    static let fencedCall = """
    ```json
    {"name": "current_time", "arguments": {"timezone": "Europe/Istanbul"}}
    ```
    """
    static let answer = "It is 6 October 2026 at 03:29 in Istanbul."

    private func makeAgent(_ replies: [String], tool: CountingTool) -> (Agent, ScriptedFMFactory) {
        let factory = ScriptedFMFactory(replies)
        let model = AppleFoundationModel(sessionFactory: factory)
        return (Agent(model: model, tools: [tool], systemPrompt: "Be brief.", retryStrategy: nil), factory)
    }

    // MARK: - the regression

    /// The exact shape of the bug: FM echoes the call back after the result.
    /// One tool execution, one assistant answer, `end_turn`.
    func testRepeatedCallAfterResultRunsToolOnceAndAnswersOnce() async throws {
        let tool = CountingTool()
        // 1) fenced call  2) the SAME call again (what FM really does)  3) the answer, once re-asked
        let (agent, factory) = makeAgent([Self.fencedCall, Self.fencedCall, Self.answer], tool: tool)

        let result = try await agent("what time is it in Istanbul?")

        XCTAssertEqual(tool.calls, 1, "the tool must run exactly once")
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertEqual(result.text, Self.answer)

        let messages = await agent.messages
        let answers = messages.filter { $0.role == .assistant && !$0.text.isEmpty }
        XCTAssertEqual(answers.count, 1, "exactly one assistant answer, not two")
        XCTAssertEqual(messages.filter { $0.role == .assistant && $0.hasToolUse }.count, 1)
        let toolCallCount = await agent.eventLoopMetrics.toolCallCount
        XCTAssertEqual(toolCallCount, 1)
        XCTAssertEqual(factory.promptCount, 3, "one re-ask, not an endless loop")
    }

    /// The other half of the symptom: FM answers *and* repeats the call in the
    /// same turn. The answer must stand on its own and the tool must not re-run.
    func testAnswerPlusRepeatedCallEndsTheTurn() async throws {
        let tool = CountingTool()
        let (agent, _) = makeAgent([Self.fencedCall, Self.answer + "\n" + Self.fencedCall], tool: tool)

        let result = try await agent("what time is it in Istanbul?")

        XCTAssertEqual(tool.calls, 1)
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertTrue(result.text.contains("03:29"), "got: \(result.text)")
        let answers = (await agent.messages).filter { $0.role == .assistant && !$0.text.isEmpty }
        XCTAssertEqual(answers.count, 1)
    }

    /// A *different* call after a result is legitimate multi-step work and must
    /// still go through — the guard is about repeats, not about second tools.
    func testDifferentCallAfterResultStillRuns() async throws {
        let time = CountingTool()
        let calcCalls = LockedCount()
        let calculator = ClosureTool(name: "calculator", description: "Evaluates arithmetic.",
                                     parameters: ToolSchema.object(["expression": ToolSchema.string("e.g. 23*47")], required: ["expression"])) { _ in
            calcCalls.bump(); return "1081"
        }
        let factory = ScriptedFMFactory([
            Self.fencedCall,
            "```json\n{\"name\": \"calculator\", \"arguments\": {\"expression\": \"23*47\"}}\n```",
            "It is 03:29 in Istanbul and 23*47 = 1081.",
        ])
        let agent = Agent(model: AppleFoundationModel(sessionFactory: factory), tools: [time, calculator], retryStrategy: nil)

        let result = try await agent("time in Istanbul, and 23*47?")

        XCTAssertEqual(time.calls, 1)
        XCTAssertEqual(calcCalls.value, 1)
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertTrue(result.text.contains("1081"))
    }

    /// Two calls in one turn (FM emits two fences) still run concurrently, once each.
    func testTwoFencedCallsInOneTurnRunOnceEach() async throws {
        let time = CountingTool()
        let calcCalls = LockedCount()
        let calculator = ClosureTool(name: "calculator", description: "Evaluates arithmetic.",
                                     parameters: ToolSchema.object(["expression": ToolSchema.string("e.g. 23*47")], required: ["expression"])) { _ in
            calcCalls.bump(); return "1081"
        }
        let two = Self.fencedCall + "\n\n```json\n{\"name\": \"calculator\", \"arguments\": {\"expression\": \"23*47\"}}\n```"
        let factory = ScriptedFMFactory([two, "It is 03:29 in Istanbul and 23*47 = 1081."])
        let agent = Agent(model: AppleFoundationModel(sessionFactory: factory), tools: [time, calculator], retryStrategy: nil)

        let result = try await agent("time in Istanbul, and 23*47?")

        XCTAssertEqual(time.calls, 1)
        XCTAssertEqual(calcCalls.value, 1)
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertEqual(factory.promptCount, 2)
    }

    /// The model that only ever repeats itself must still end the turn (no infinite loop)
    /// and must show the user what the tool produced rather than nothing.
    func testHopelessRepeaterStillEndsTheTurn() async throws {
        let tool = CountingTool()
        let (agent, factory) = makeAgent([Self.fencedCall, Self.fencedCall, Self.fencedCall], tool: tool)

        let result = try await agent("what time is it in Istanbul?")

        XCTAssertEqual(tool.calls, 1)
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertTrue(result.text.contains("03:29"), "got: \(result.text)")
        XCTAssertEqual(factory.promptCount, 3)
    }

    // MARK: - the prompt rendering that caused it

    /// The answer turn must not carry tool markup (that is what FM mimicked) and
    /// must say the tools already ran.
    func testAnswerModePromptCarriesNoToolMarkup() {
        let use = ToolUse(toolUseId: "tooluse_ab12cd34", name: "current_time", input: ["timezone": "Europe/Istanbul"])
        let messages: [Message] = [
            .user("what time is it in Istanbul?"),
            .assistant(text: "", toolUses: [use]),
            .toolResults([ToolResult(toolUseId: use.toolUseId, name: use.name, content: #"{"pretty":"6 October 2026 at 03:29"}"#)]),
        ]
        let built = AppleFMPrompt.build(messages: messages, toolSpecs: [CountingTool().toolSpec], systemPrompt: nil)

        XCTAssertEqual(built.mode, .answer)
        XCTAssertFalse(built.prompt.contains("<tool_call>"))
        XCTAssertFalse(built.prompt.contains("<tool_response"))
        XCTAssertTrue(built.prompt.contains("already been run"))
        XCTAssertTrue(built.prompt.contains("what time is it in Istanbul?"))
        XCTAssertTrue(built.prompt.contains("6 October 2026 at 03:29"))
        XCTAssertTrue(built.instructions.contains("never ask for that tool again"))
        // Raw JSON schemas in `instructions` make FM fail with tokengeneration Code=10.
        XCTAssertFalse(built.instructions.contains("\"type\": \"function\""))
        XCTAssertFalse(built.instructions.contains("\"type\":\"function\""))
    }

    func testCallModePromptIsTheBareQuestion() {
        let built = AppleFMPrompt.build(messages: [.user("what time is it in Istanbul?")],
                                        toolSpecs: [CountingTool().toolSpec], systemPrompt: "Be brief.")
        XCTAssertEqual(built.mode, .call)
        XCTAssertEqual(built.prompt, "what time is it in Istanbul?")
        XCTAssertTrue(built.instructions.hasPrefix("Be brief."))
        XCTAssertTrue(built.instructions.contains("- current_time(timezone?: string) — Current date and time"))
    }

    func testToolDocsAreCompactAndOrderRequiredFirst() {
        let spec = ToolSpec(name: "http", description: "Makes a request.",
                            inputSchema: ToolSchema.object(["url": ToolSchema.string("the URL"),
                                                            "method": ToolSchema.string("GET/POST")],
                                                           required: ["url"]))
        XCTAssertEqual(AppleFMPrompt.toolDocs([spec]), "- http(url: string, method?: string) — Makes a request.")
    }

    // MARK: - the guard itself

    func testRepeatGuardMatchesRegardlessOfKeyOrderAndLetsErrorsRetry() {
        let a = ToolUse(toolUseId: "t1", name: "http", input: ["url": "https://x", "method": "GET"])
        let b = ToolUse(toolUseId: "t2", name: "http", input: ["method": "GET", "url": "https://x"])
        let other = ToolUse(toolUseId: "t3", name: "http", input: ["url": "https://y", "method": "GET"])

        let answered = ToolCallRepeatGuard(messages: [
            .user("go"), .assistant(text: "", toolUses: [a]),
            .toolResults([ToolResult(toolUseId: "t1", name: "http", content: "ok")]),
        ])
        XCTAssertTrue(answered.isRepeat(b), "same call, different key order")
        XCTAssertFalse(answered.isRepeat(other))

        let errored = ToolCallRepeatGuard(messages: [
            .user("go"), .assistant(text: "", toolUses: [a]),
            .toolResults([ToolResult(toolUseId: "t1", name: "http", status: .error, content: "timeout")]),
        ])
        XCTAssertFalse(errored.isRepeat(b), "a failed call may be retried")
        XCTAssertTrue(ToolCallRepeatGuard().isEmpty)
    }

    // MARK: - the real model, when this machine has one

    /// End-to-end against the REAL Apple Intelligence model: one question, one
    /// tool, one execution, one answer. Skipped wherever Apple Intelligence is
    /// not available (CI, the simulator, an ineligible Mac) — which is exactly
    /// why the scripted seam above exists.
    func testLiveFoundationModelsRunsTheToolOnceAndAnswers() async throws {
        let availability = AppleFoundationModel.availability()
        try XCTSkipUnless(availability.available, "Apple Intelligence unavailable: \(availability.reason)")

        let tool = CountingTool()
        let agent = Agent(model: AppleFoundationModel(), tools: [tool],
                          systemPrompt: "Be brief.", retryStrategy: nil)
        let result = try await agent("what time is it in Istanbul?")

        XCTAssertEqual(tool.calls, 1, "the real model made the tool run \(tool.calls)x")
        XCTAssertEqual(result.stopReason, .endTurn)
        let answers = (await agent.messages).filter { $0.role == .assistant && !$0.text.isEmpty }
        XCTAssertEqual(answers.count, 1, "answers: \(answers.map(\.text))")
        XCTAssertFalse(result.text.contains("\"name\""), "the answer must not be JSON: \(result.text)")
        XCTAssertTrue(result.text.contains("03:29") || result.text.lowercased().contains("october"),
                      "answer should use the tool result: \(result.text)")
    }

    /// Default gate behaviour (MLX, GGUF) is untouched: no suppression without a closure.
    func testGateWithoutSuppressionKeepsEveryCall() {
        var gate = ToolCallStreamGate(family: .generic)
        _ = gate.feed(Self.fencedCall)
        let events = gate.finish()
        XCTAssertTrue(gate.suppressedCalls.isEmpty)
        XCTAssertTrue(events.contains { if case .messageStop(.toolUse) = $0 { return true }; return false })
    }
}

/// A thread-safe counter for closure tools.
final class LockedCount: Sendable {
    private let n = Mutex(0)
    func bump() { n.withLock { $0 += 1 } }
    var value: Int { n.withLock { $0 } }
}

extension String {
    /// Split into fixed-size pieces, to simulate streaming.
    func chunked(_ size: Int) -> [String] {
        var out: [String] = []
        var i = startIndex
        while i < endIndex {
            let j = index(i, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(String(self[i..<j]))
            i = j
        }
        return out
    }
}
