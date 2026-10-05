import XCTest
import Loopl

final class ToolCallParserTests: XCTestCase {
    func testHermesSingleCall() {
        let r = ToolCallParser(family: .hermes).parse("Let me check.\n<tool_call>\n{\"name\": \"current_time\", \"arguments\": {\"timezone\": \"Europe/Istanbul\"}}\n</tool_call>")
        XCTAssertEqual(r.text, "Let me check.")
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls[0].name, "current_time")
        XCTAssertEqual(r.calls[0].input["timezone"], .string("Europe/Istanbul"))
    }

    func testHermesTwoCallsKeepOrder() {
        let r = ToolCallParser(family: .hermes).parse("<tool_call>{\"name\":\"a\",\"arguments\":{}}</tool_call><tool_call>{\"name\":\"b\",\"arguments\":{\"x\":1}}</tool_call>")
        XCTAssertEqual(r.calls.map(\.name), ["a", "b"])
        XCTAssertEqual(r.calls[1].input["x"], .number(1))
        XCTAssertEqual(r.text, "")
    }

    func testQwen3ThinkingIsStripped() {
        let r = ToolCallParser(family: .hermes).parse("<think>\nI should compute.\n</think>\n<tool_call>\n{\"name\": \"calculator\", \"arguments\": {\"expression\": \"23*47\"}}\n</tool_call>")
        XCTAssertEqual(r.calls.first?.name, "calculator")
        XCTAssertEqual(r.text, "")
    }

    func testLlama3PythonTag() {
        let r = ToolCallParser(family: .llama3).parse("<|python_tag|>{\"name\": \"calculator\", \"parameters\": {\"expression\": \"2+2\"}}<|eom_id|>")
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls[0].name, "calculator")
        XCTAssertEqual(r.calls[0].input["expression"], .string("2+2"))
    }

    func testLlama3BareJSONMessage() {
        let r = ToolCallParser(family: .llama3).parse("{\"name\": \"current_time\", \"parameters\": {\"timezone\": \"Europe/Istanbul\"}}")
        XCTAssertEqual(r.calls.first?.name, "current_time")
        XCTAssertEqual(r.text, "")
    }

    func testGenericFencedJSON() {
        let r = ToolCallParser(family: .generic).parse("Sure.\n```json\n{\"name\": \"calculator\", \"arguments\": {\"expression\": \"sqrt(16)\"}}\n```")
        XCTAssertEqual(r.calls.first?.name, "calculator")
        XCTAssertEqual(r.text, "Sure.")
    }

    func testPlainAnswerHasNoCalls() {
        let r = ToolCallParser(family: .hermes).parse("It is 1081. Here is some JSON for you: {\"a\": 1} — no name key.")
        XCTAssertTrue(r.calls.isEmpty)
        XCTAssertTrue(r.text.contains("1081"))
    }

    func testMalformedJSONIsNotACall() {
        let r = ToolCallParser(family: .hermes).parse("<tool_call>{\"name\": \"x\", \"arguments\": {broken</tool_call>")
        XCTAssertTrue(r.calls.isEmpty)
    }

    func testArgumentsAsJSONString() {
        let r = ToolCallParser(family: .generic).parse("{\"name\": \"calculator\", \"arguments\": \"{\\\"expression\\\": \\\"1+1\\\"}\"}")
        XCTAssertEqual(r.calls.first?.input["expression"], .string("1+1"))
    }

    func testTruncatedCallIsRepaired() {
        let r = ToolCallParser(family: .hermes).parse("<tool_call>{\"name\": \"recall\", \"arguments\": {\"key\": \"x\"</tool_call>")
        // Markup pattern fails (unbalanced), fallback bare-object closing repairs it.
        XCTAssertEqual(r.calls.first?.name, "recall")
    }
}

final class ToolCallStreamGateTests: XCTestCase {
    func run(_ pieces: [String], family: ToolFamily = .hermes, stop: StopReason = .endTurn) -> (text: String, stop: StreamAssembler.Stop) {
        var gate = ToolCallStreamGate(family: family)
        var a = StreamAssembler()
        var text = ""
        for p in pieces { for ev in gate.feed(p) { for e in a.feed(ev) { if case .text(let t) = e { text += t } } } }
        for ev in gate.finish(stopReason: stop) { for e in a.feed(ev) { if case .text(let t) = e { text += t } } }
        return (text, a.finish())
    }

    func testPlainTextStreamsLiveAndEndsEndTurn() {
        let r = run(["Hel", "lo ", "wor", "ld."])
        XCTAssertEqual(r.text, "Hello world."); XCTAssertEqual(r.stop.stopReason, .endTurn); XCTAssertEqual(r.stop.message.text, "Hello world.")
    }

    func testMarkupSplitAcrossChunksBecomesToolUse() {
        let r = run(["Sure. <to", "ol_call>{\"name\": \"calc\", \"argu", "ments\": {\"x\": 1}}</tool_c", "all>"])
        XCTAssertEqual(r.text.trimmingCharacters(in: .whitespaces), "Sure.", "live deltas may end with the separator that preceded the markup")
        XCTAssertEqual(r.stop.stopReason, .toolUse)
        XCTAssertEqual(r.stop.message.toolUses.map(\.name), ["calc"])
        XCTAssertEqual(r.stop.message.toolUses[0].input["x"], .number(1))
        XCTAssertFalse(r.stop.message.text.contains("<tool_call>"))
    }

    func testThinkBlockIsReasoningNotText() {
        let r = run(["<think>", "hmm", "</think>", "\n\n", "pong"])
        XCTAssertEqual(r.text, "pong")
        XCTAssertEqual(r.stop.message.reasoning, "hmm")
        XCTAssertEqual(r.stop.message.text, "pong")
    }

    func testAngleBracketThatIsNotAnOpenerIsReleased() {
        let r = run(["a <b> c", " and 1 < 2"])
        XCTAssertEqual(r.text, "a <b> c and 1 < 2")
    }

    func testBareJSONObjectIsAToolCall() {
        let r = run(["{\"name\": \"f\", \"arguments\": {}}"], family: .generic)
        XCTAssertEqual(r.stop.message.toolUses.map(\.name), ["f"]); XCTAssertEqual(r.text, "")
    }

    func testMaxTokensKeepsStopReason() {
        let r = run(["partial answer"], stop: .maxTokens)
        XCTAssertEqual(r.stop.stopReason, .maxTokens); XCTAssertEqual(r.text, "partial answer")
    }
}
