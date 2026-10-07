import XCTest
@testable import Loopl

/// Phase 7 `ask_user`: the spec the model emits, the answer shapes the model reads, the privacy rule for passwords,
/// the Transcript card lifecycle, and the real suspend/resume + timeout through an `Agent`.
final class AskUserTests: XCTestCase {

    func use(_ args: [String: JSONValue], id: String = "a1") -> ToolUse { ToolUse(toolUseId: id, name: AskUserTool.toolName, input: args) }

    // MARK: spec parsing (what a small model is allowed to emit)

    func testParsesEveryTypeAndNormalisesLooseOptions() throws {
        let r = try AskUserRequest(args: ["type": "select", "text": "Which?", "options": ["a", ["b", "Bee"], ["value": "c", "label": "Cee"], ["label": "d"], 3]])
        XCTAssertEqual(r.type, .select)
        XCTAssertEqual(r.options.map(\.value), ["a", "b", "c", "d", "3"])
        XCTAssertEqual(r.options.map(\.label), ["a", "Bee", "Cee", "d", "3"])
        XCTAssertEqual(r.timeoutSeconds, AskUserRequest.defaultTimeout)

        let one = try AskUserRequest(args: ["type": "buttons", "text": "ok?", "options": "only"])
        XCTAssertEqual(one.options.map(\.value), ["only"], "a single string instead of an array is accepted")

        let f = try AskUserRequest(args: ["type": "form", "text": "details", "fields": [
            ["name": "email", "required": true], "nickname", ["name": "password"], ["name": "n", "type": "number", "default": 2], ["name": "on", "type": "toggle", "default": true]]])
        XCTAssertEqual(f.fields.map(\.name), ["email", "nickname", "password", "n", "on"])
        XCTAssertEqual(f.fields.map(\.type), [.text, .text, .password, .number, .toggle], "a field called password is a password even without a type")
        XCTAssertEqual(f.fields[0].required, true)
        XCTAssertEqual(f.fields[3].default, "2")
        XCTAssertEqual(f.fields[4].default, "true")
        XCTAssertEqual(f.secretFieldNames, ["password"])
    }

    func testTimeoutIsClampedAndLooseKeysAccepted() throws {
        XCTAssertEqual(try AskUserRequest(args: ["type": "confirm", "text": "x", "timeout_s": 1]).timeoutSeconds, 5)
        XCTAssertEqual(try AskUserRequest(args: ["type": "confirm", "text": "x", "timeout_sec": 99_999]).timeoutSeconds, 3600)
        XCTAssertEqual(try AskUserRequest(args: ["type": "confirm", "text": "x", "timeout_s": "nope"]).timeoutSeconds, 180)
        XCTAssertEqual(try AskUserRequest(args: ["type": "Confirm", "text": "x"]).type, .confirm, "case-insensitive type")
    }

    func testBadSpecsAreRepairableErrors() {
        func message(_ args: [String: JSONValue]) -> String {
            do { _ = try AskUserRequest(args: args); return "" } catch { return (error as? ToolError)?.message ?? "\(error)" }
        }
        XCTAssertTrue(message(["type": "select", "text": "pick"]).contains("options required for select"))
        XCTAssertTrue(message(["type": "multiselect", "text": "pick", "options": []]).contains("options required"))
        XCTAssertTrue(message(["type": "form", "text": "fill"]).contains("fields required for form"))
        XCTAssertTrue(message(["type": "form", "text": "fill", "fields": [["type": "text"]]]).contains("needs a name"))
        XCTAssertTrue(message(["type": "wizard", "text": "x"]).contains("type must be one of"))
        XCTAssertTrue(message(["type": "input", "text": "  "]).contains("text (the question) is required"))
    }

    func testSpecRoundTripsThroughTheInterruptReasonAndToolArgs() throws {
        let r = try AskUserRequest(args: ["type": "form", "text": "Wi-Fi", "title": "Join", "fields": [["name": "ssid", "label": "Network", "default": "office", "required": true], ["name": "pw", "type": "password"]], "timeout_s": 60])
        let back = AskUserRequest(interruptReason: r.interruptReason)
        XCTAssertEqual(back, r)
        let again = try AskUserRequest(args: r.toolArgs)
        XCTAssertEqual(again, r, "toolArgs is a spec the parser accepts unchanged (History saves it)")
        XCTAssertNil(AskUserRequest(interruptReason: .string("not a spec")))
    }

    // MARK: answers (what the model reads) + the privacy rule

    func testAnswerShapesForTheModel() {
        XCTAssertEqual(AskUserAnswer.answered(.bool(true)).toolResult.compact, #"{"ok":true,"value":true}"#)
        XCTAssertEqual(AskUserAnswer.answered(.array(["a", "b"])).toolResult.compact, #"{"ok":true,"value":["a","b"]}"#)
        XCTAssertEqual(AskUserAnswer.cancelled.toolResult.compact, #"{"cancelled":true,"ok":false}"#)
        XCTAssertEqual(AskUserAnswer.timedOut.toolResult.compact, #"{"ok":false,"timeout":true}"#)
        // Interrupt response ⇄ answer.
        XCTAssertEqual(AskUserAnswer(interruptResponse: .null), .timedOut, ".null is what the agent substitutes on timeout")
        XCTAssertEqual(AskUserAnswer(interruptResponse: ["cancelled": true]), .cancelled)
        XCTAssertEqual(AskUserAnswer(interruptResponse: ["value": "x"]), .answered("x"))
        XCTAssertEqual(AskUserAnswer(interruptResponse: AskUserAnswer.answered(["k": 1]).interruptResponse), .answered(["k": 1]))
        // Saved tool result ⇄ answer (History reopening).
        XCTAssertEqual(AskUserAnswer(toolResult: #"{"ok":true,"value":"Oda"}"#), .answered("Oda"))
        XCTAssertEqual(AskUserAnswer(toolResult: #"{"ok":false,"timeout":true}"#), .timedOut)
        XCTAssertEqual(AskUserAnswer(toolResult: #"{"ok":false,"cancelled":true}"#), .cancelled)
        XCTAssertNil(AskUserAnswer(toolResult: "ERROR: ask_user: options required"))
    }

    func testPasswordsAreMaskedForTheTranscriptButReachTheModel() throws {
        let r = try AskUserRequest(args: ["type": "form", "text": "login", "fields": [["name": "user"], ["name": "password", "type": "password"], ["name": "pin", "type": "password"]]])
        let answer = AskUserAnswer.answered(["user": "ali", "password": "hunter2", "pin": ""])
        let masked = answer.masked(for: r)
        XCTAssertEqual(masked, .answered(["user": "ali", "password": .string(AskUserAnswer.mask), "pin": ""]), "non-empty secrets masked, empty left empty")
        XCTAssertFalse(masked.toolResult.compact.contains("hunter2"))
        XCTAssertTrue(answer.toolResult.compact.contains("hunter2"), "the tool result the model reads carries the value — that is the point of asking")
        XCTAssertEqual(AskUserAnswer.answered("plain").masked(for: r), .answered("plain"), "non-object answers untouched")
    }

    func testSummaryLines() throws {
        let sel = try AskUserRequest(args: ["type": "select", "text": "w", "options": [["value": "oda", "label": "Oda · Turkish"], "Antica"]])
        XCTAssertEqual(AskUserAnswer.answered("oda").summary(for: sel), "Oda · Turkish")
        XCTAssertEqual(AskUserAnswer.answered("unknown").summary(for: sel), "unknown")
        let multi = try AskUserRequest(args: ["type": "multiselect", "text": "w", "options": ["a", "b", "c"]])
        XCTAssertEqual(AskUserAnswer.answered(["a", "c"]).summary(for: multi), "a, c")
        XCTAssertEqual(AskUserAnswer.answered([]).summary(for: multi), "None picked")
        let confirm = try AskUserRequest(args: ["type": "confirm", "text": "w"])
        XCTAssertEqual(AskUserAnswer.answered(.bool(false)).summary(for: confirm), "No")
        XCTAssertEqual(AskUserAnswer.cancelled.summary(for: confirm), "Cancelled")
        XCTAssertEqual(AskUserAnswer.timedOut.summary(for: confirm), "No answer in time")
        let form = try AskUserRequest(args: ["type": "form", "text": "w", "fields": ["a"]])
        XCTAssertEqual(AskUserAnswer.answered(["a": "x"]).summary(for: form), "Submitted")
    }

    // MARK: Transcript card lifecycle

    func testTranscriptTurnsTheToolRowIntoACardAndSettlesItMasked() throws {
        let r = try AskUserRequest(args: ["type": "form", "text": "login", "fields": [["name": "password", "type": "password"]]])
        var t = Transcript()
        t.user("log me in")
        let u = use(r.toolArgs)
        t.apply(.modelMessage(.assistant(text: "", toolUses: [u])))
        t.apply(.toolStarted(u))
        XCTAssertEqual(t.items.count, 2)
        t.apply(.interruptRaised(Interrupt(id: AskUserTool.interruptId(toolUseId: "a1"), name: AskUserTool.interruptName, reason: r.interruptReason)))
        XCTAssertEqual(t.items.count, 2, "the card REPLACES the tool's own row — no duplicate")
        guard case .ask("a1", r, nil) = t.items[1].kind else { return XCTFail("expected a pending ask card, got \(t.items[1].kind)") }
        XCTAssertEqual(t.pendingAsks, ["a1"])

        let answer = AskUserAnswer.answered(["password": "hunter2"])
        t.apply(.interruptResolved(id: AskUserTool.interruptId(toolUseId: "a1"), response: answer.interruptResponse))
        t.apply(.toolResult(ToolResult(toolUseId: "a1", name: AskUserTool.toolName, content: answer.toolResult.compact)))
        XCTAssertEqual(t.items.count, 2, "the tool result folds into the card")
        guard case .ask("a1", _, let settled?) = t.items[1].kind else { return XCTFail("expected a settled card") }
        XCTAssertEqual(settled, .answered(["password": .string(AskUserAnswer.mask)]), "the transcript never holds the password")
        XCTAssertTrue(t.pendingAsks.isEmpty)
    }

    func testOtherInterruptsStillBecomeNotesAndTimeoutSettlesTheCard() throws {
        var t = Transcript()
        t.apply(.interruptRaised(Interrupt(id: "tool:x:how_many", name: "how_many", reason: .string("?"))))
        guard case .note(let s) = t.items.last?.kind else { return XCTFail() }
        XCTAssertTrue(s.contains("how_many"))

        let r = try AskUserRequest(args: ["type": "confirm", "text": "sure?"])
        t.apply(.interruptRaised(Interrupt(id: AskUserTool.interruptId(toolUseId: "a9"), name: AskUserTool.interruptName, reason: r.interruptReason)))
        t.apply(.interruptResolved(id: AskUserTool.interruptId(toolUseId: "a9"), response: .null))
        guard case .ask("a9", _, .timedOut?) = t.items.last?.kind else { return XCTFail("timeout settles the card as timedOut: \(String(describing: t.items.last?.kind))") }
    }

    func testRebuiltHistoryKeepsTheAskAsAMaskedToolPairAndDropsOpenOnes() throws {
        let r = try AskUserRequest(args: ["type": "form", "text": "login", "fields": [["name": "pw", "type": "password"]]])
        var t = Transcript()
        t.user("hi")
        t.items.append(TranscriptItem(kind: .ask(toolUseId: "a1", r, answer: .answered(["pw": .string(AskUserAnswer.mask)]))))
        t.items.append(TranscriptItem(kind: .assistant("ok")))
        t.user("again")
        t.items.append(TranscriptItem(kind: .ask(toolUseId: "a2", r, answer: nil)))
        let messages = t.messages
        let uses = messages.flatMap(\.toolUses)
        XCTAssertEqual(uses.map(\.toolUseId), ["a1"], "the open card is dropped like an unfinished tool")
        XCTAssertEqual(uses.first?.name, AskUserTool.toolName)
        XCTAssertEqual(uses.first?.input["type"], "form")
        let results = messages.flatMap(\.toolResults)
        XCTAssertEqual(results.first?.content, AskUserAnswer.answered(["pw": .string(AskUserAnswer.mask)]).toolResult.compact)
    }

    // MARK: through a real Agent (the suspend path the ApprovalCard uses)

    func testToolRaisesTheInterruptAndReturnsTheAnswerAsJSON() async throws {
        let args: [String: JSONValue] = ["type": "select", "text": "Where?", "options": ["Oda", "Antica"]]
        let model = FakeModel(turns: [.toolUse([use(args)]), .text("booked")])
        let agent = Agent(model: model, tools: [AskUserTool()], retryStrategy: nil)
        var raised: Interrupt?
        var result: ToolResult?
        for try await e in agent.stream("book me a table") {
            if case .interruptRaised(let i) = e {
                raised = i
                XCTAssertEqual(i.id, "tool:a1:ask_user")
                XCTAssertEqual(i.timeout, 180, "the tool's own wait rides on the interrupt")
                XCTAssertEqual(AskUserRequest(interruptReason: i.reason ?? .null)?.options.map(\.value), ["Oda", "Antica"])
                Task { await agent.resolve(interrupt: i.id, response: AskUserAnswer.answered("Oda").interruptResponse) }
            }
            if case .toolResult(let r) = e { result = r }
        }
        XCTAssertNotNil(raised)
        XCTAssertEqual(result?.status, .success)
        XCTAssertEqual(result?.content, #"{"ok":true,"value":"Oda"}"#)
    }

    func testCancelAndTimeoutReachTheModelHonestly() async throws {
        // Cancel
        let model = FakeModel(turns: [.toolUse([use(["type": "confirm", "text": "Delete?"])]), .text("left it")])
        let agent = Agent(model: model, tools: [AskUserTool()], retryStrategy: nil)
        var content: String?
        for try await e in agent.stream("delete everything") {
            if case .interruptRaised(let i) = e { Task { await agent.resolve(interrupt: i.id, response: AskUserAnswer.cancelled.interruptResponse) } }
            if case .toolResult(let r) = e { content = r.content }
        }
        XCTAssertEqual(content, #"{"cancelled":true,"ok":false}"#)

        // Timeout: timeout_s is clamped to ≥ 5 s, so the agent's wait is 5 s here; nobody answers.
        let slow = FakeModel(turns: [.toolUse([use(["type": "input", "text": "name?", "timeout_s": 1], id: "t1")]), .text("no answer")])
        let agent2 = Agent(model: slow, tools: [AskUserTool()], retryStrategy: nil)
        let t0 = Date()
        var timedOut: String?
        var resolvedWith: JSONValue?
        for try await e in agent2.stream("rename") {
            if case .interruptResolved(_, let response) = e { resolvedWith = response }
            if case .toolResult(let r) = e { timedOut = r.content }
        }
        XCTAssertEqual(timedOut, #"{"ok":false,"timeout":true}"#)
        XCTAssertEqual(resolvedWith, .null)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), 4.5, "waited the clamped 5 s, not the 120 s approval default")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 30)
    }

    func testBadSpecIsAnErrorResultWithoutRaising() async throws {
        let model = FakeModel(turns: [.toolUse([use(["type": "select", "text": "pick"])]), .text("fixed")])
        let agent = Agent(model: model, tools: [AskUserTool()], retryStrategy: nil)
        var raised = 0
        var result: ToolResult?
        for try await e in agent.stream("x") {
            if case .interruptRaised = e { raised += 1 }
            if case .toolResult(let r) = e { result = r }
        }
        XCTAssertEqual(raised, 0)
        XCTAssertEqual(result?.status, .error)
        XCTAssertTrue(result?.content.contains("options required for select") == true, result?.content ?? "")
    }

    func testOutsideAnAgentTheToolSaysSo() async {
        do { _ = try await AskUserTool().call(["type": "confirm", "text": "x"]); XCTFail("expected an error") }
        catch { XCTAssertTrue((error as? ToolError)?.message.contains("no one to ask") == true, "\(error)") }
    }
}
