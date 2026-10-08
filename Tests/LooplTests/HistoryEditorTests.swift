import XCTest
@testable import Loopl

/// `HistoryEditor` — the pure half of `manage_messages`. Every invariant of tiny-tech's manage-messages.ts, checked
/// on loopl `Message`s: turn parsing, the ACTIVE turn never edited, synthetic results for orphans, structure gate,
/// reasoning kept whole or gone with its tool blocks, lenient argument parsing for small models.
final class HistoryEditorTests: XCTestCase {
    // One fixture conversation: 4 complete turns before the active one, tool-heavy.
    //   t0: "weather" → time tool → answer
    //   t1: "math" → calculator ×2 (one carrier) → answer (with reasoning before the tool call)
    //   t2: "hi" → plain answer (no tools)
    //   t3: "fetch" → http → answer
    //   ACTIVE: "long?" → manage_messages (unresolved — we are inside it)
    static func use(_ name: String, _ id: String, _ input: [String: JSONValue] = [:]) -> ToolUse { ToolUse(toolUseId: id, name: name, input: input) }
    static func res(_ name: String, _ id: String, _ text: String) -> ToolResult { ToolResult(toolUseId: id, name: name, content: text) }

    static let selfId = "tooluse_self"
    static func fixture() -> [Message] {
        [
            .user("weather in Istanbul?"),
            .assistant(text: "", toolUses: [use("current_time", "t0a", ["timezone": "Europe/Istanbul"])]),
            .toolResults([res("current_time", "t0a", "Monday 21:00 (Europe/Istanbul)")]),
            .assistant("It is 21:00 in Istanbul."),
            .user("what is 23*47 and 2^10?"),
            Message(role: .assistant, content: [.reasoning("two calculations"), .toolUse(use("calculator", "t1a", ["expression": "23*47"])), .toolUse(use("calculator", "t1b", ["expression": "2^10"]))]),
            .toolResults([res("calculator", "t1a", "23*47 = 1081"), res("calculator", "t1b", "2^10 = 1024")]),
            .assistant("1081 and 1024."),
            .user("hi"),
            .assistant("Hello!"),
            .user("fetch example.com"),
            .assistant(text: "", toolUses: [use("http", "t3a", ["url": "https://example.com"])]),
            .toolResults([res("http", "t3a", String(repeating: "<html>", count: 200))]),
            .assistant("Example Domain."),
            .user("the context is long — tidy it"),
            .assistant(text: "", toolUses: [use("manage_messages", selfId, ["action": "compact"])]),
        ]
    }

    func testParseTurnsAndActive() {
        let m = Self.fixture()
        let turns = HistoryEditor.parseTurns(m)
        XCTAssertEqual(turns.map { [$0.start, $0.end] }, [[0, 4], [4, 8], [8, 10], [10, 14], [14, 16]])
        XCTAssertEqual(HistoryEditor.activeTurnStart(m), 14)
        XCTAssertEqual(HistoryEditor.pendingToolUseIds(m), [Self.selfId], "only the running call is unresolved")
        XCTAssertEqual(HistoryEditor.activeToolIds(m, selfId: Self.selfId), [Self.selfId])
        let split = HistoryEditor.splitActive(m)
        XCTAssertEqual(split.droppable.count, 14); XCTAssertEqual(split.active.count, 2)
        // Preamble: a leading toolResult carrier belongs to no turn.
        let pre = [Message.toolResults([Self.res("x", "p", "r")])] + m
        XCTAssertEqual(HistoryEditor.parseTurns(pre).first?.start, 1)
    }

    func testCompactDefaultKeepsLastThreeTurnsAndTheActiveOne() throws {
        let m = Self.fixture()
        let out = try HistoryEditor.apply(.init(action: .compact), to: m, selfId: Self.selfId)
        // 4 droppable turns, keep 3 → only t0 is compacted (its 2 tool blocks go, the text stays).
        XCTAssertEqual(out.edit?.action, .compact)
        XCTAssertEqual(out.edit?.turnsAffected, 1)
        XCTAssertEqual(out.edit?.toolBlocksRemoved, 2)
        XCTAssertEqual(out.messages.count, m.count - 2, "the toolUse-only assistant message and the carrier are emptied and dropped")
        XCTAssertEqual(out.messages[0].text, "weather in Istanbul?")
        XCTAssertEqual(out.messages[1].text, "It is 21:00 in Istanbul.")
        XCTAssertTrue(out.messages.suffix(2).elementsEqual(m.suffix(2)), "the active turn is byte-identical")
        XCTAssertTrue(HistoryEditor.validateStructure(Array(out.messages.dropLast(2))).ok, "everything before the active turn pairs up")
        XCTAssertEqual(out.edit?.summary, "The model tidied 1 turn of notes · your conversation is unchanged")
        XCTAssertTrue(out.text.hasPrefix("Compacted 1 turn(s), removed 2 tool blocks"), out.text)
    }

    func testCompactKeepLastZeroStripsEveryOldTurnButReasoningOnlyMessagesStayWhole() throws {
        var m = Self.fixture()
        m.insert(Message(role: .assistant, content: [.reasoning("just thinking")]), at: 9)   // reasoning-only, no tools, in t2
        var req = HistoryEditor.Request(action: .compact); req.keepLast = 0
        let out = try HistoryEditor.apply(req, to: m, selfId: Self.selfId)
        XCTAssertEqual(out.edit?.turnsAffected, 4)
        XCTAssertEqual(out.edit?.toolBlocksRemoved, 2 + 4 + 2)
        XCTAssertFalse(out.messages.dropLast(2).contains { HistoryEditor.hasTool($0) })
        // t1's assistant message carried reasoning + two toolUses: reasoning goes WITH the tool blocks → message emptied → gone.
        XCTAssertFalse(out.messages.contains { $0.reasoning == "two calculations" })
        // The reasoning-only message had no tool blocks → kept whole.
        XCTAssertTrue(out.messages.contains { $0.reasoning == "just thinking" })
        XCTAssertEqual(out.messages.compactMap { $0.role == .user ? $0.text : nil }.filter { !$0.isEmpty }.count, 5, "every user query's text survives")
    }

    func testCompactWithNothingToDoIsHonest() throws {
        let m = Array(Self.fixture().prefix(10)) + [Message.user("now"), .assistant(text: "", toolUses: [Self.use("manage_messages", "s2", [:])])]
        // t0 t1 t2 droppable, keep 3 → nothing
        let out = try HistoryEditor.apply(.init(action: .compact), to: m, selfId: "s2")
        XCTAssertNil(out.edit); XCTAssertTrue(out.text.contains("nothing to compact"), out.text)
        // Explicit turn with no tools → says so, suggests drop.
        var req = HistoryEditor.Request(action: .compact); req.turns = [2]
        let out2 = try HistoryEditor.apply(req, to: m, selfId: "s2")
        XCTAssertNil(out2.edit); XCTAssertTrue(out2.text.contains("no tool calls"), out2.text)
    }

    func testDropTurnsNeverTouchesTheActiveTurn() throws {
        let m = Self.fixture()
        var req = HistoryEditor.Request(action: .drop); req.turns = [0, 2, 99]
        let out = try HistoryEditor.apply(req, to: m, selfId: Self.selfId)
        XCTAssertEqual(out.edit?.turnsAffected, 2, "99 is out of range and ignored, 0 and 2 go")
        XCTAssertEqual(out.messages.count, m.count - 4 - 2)
        XCTAssertEqual(out.messages.first?.text, "what is 23*47 and 2^10?")
        XCTAssertTrue(out.messages.suffix(2).elementsEqual(m.suffix(2)))
        // Asking for the active turn by any number fails loudly, never silently.
        var only = HistoryEditor.Request(action: .drop); only.turns = [4]
        XCTAssertThrowsError(try HistoryEditor.apply(only, to: m, selfId: Self.selfId)) { XCTAssertTrue("\($0)".contains("no such turn"), "\($0)") }
        XCTAssertThrowsError(try HistoryEditor.apply(.init(action: .drop), to: m, selfId: Self.selfId)) { XCTAssertTrue("\($0)".contains("specify turns"), "\($0)") }
        // start/end ranges
        var range = HistoryEditor.Request(action: .drop); range.start = 1
        XCTAssertEqual(try HistoryEditor.apply(range, to: m, selfId: Self.selfId).edit?.turnsAffected, 3)
        var head = HistoryEditor.Request(action: .drop); head.end = 2
        XCTAssertEqual(try HistoryEditor.apply(head, to: m, selfId: Self.selfId).edit?.turnsAffected, 2)
    }

    func testDropToolsByIdAndByNameRefusesActiveAndInjectsSyntheticResults() throws {
        let m = Self.fixture()
        // By id: one of the two calculator calls in the same carrier → that pair goes, the other stays, structure valid.
        var byId = HistoryEditor.Request(action: .dropTools); byId.toolIds = ["t1a"]
        let out = try HistoryEditor.apply(byId, to: m, selfId: Self.selfId)
        let calls = HistoryEditor.allToolCalls(out.messages)
        XCTAssertFalse(calls.contains { $0.toolUseId == "t1a" }); XCTAssertTrue(calls.contains { $0.toolUseId == "t1b" })
        XCTAssertTrue(HistoryEditor.validateStructure(Array(out.messages.dropLast(2))).ok)
        XCTAssertFalse(out.messages.contains { $0.reasoning == "two calculations" }, "an edited message loses its reasoning too")
        XCTAssertEqual(out.edit?.summary, "The model set aside 1 tool result · your conversation is unchanged")
        // By name
        var byName = HistoryEditor.Request(action: .dropTools); byName.toolName = "calculator"
        let out2 = try HistoryEditor.apply(byName, to: m, selfId: Self.selfId)
        XCTAssertFalse(HistoryEditor.allToolCalls(out2.messages).contains { $0.name == "calculator" })
        XCTAssertEqual(out2.edit?.turnsAffected, 2)
        // The running call is locked.
        var selfDrop = HistoryEditor.Request(action: .dropTools); selfDrop.toolIds = [Self.selfId]
        XCTAssertThrowsError(try HistoryEditor.apply(selfDrop, to: m, selfId: Self.selfId)) { XCTAssertTrue("\($0)".contains("active"), "\($0)") }
        var selfByName = HistoryEditor.Request(action: .dropTools); selfByName.toolName = "manage_messages"
        let out3 = try HistoryEditor.apply(selfByName, to: m, selfId: Self.selfId)
        XCTAssertNil(out3.edit, "by name, active calls are skipped and the answer is honest: \(out3.text)")
        XCTAssertThrowsError(try HistoryEditor.apply(.init(action: .dropTools), to: m, selfId: Self.selfId))
    }

    func testSyntheticResultsRepairOrphansAndMergeIntoARealCarrier() {
        // An assistant message with two toolUses whose carrier only answers one → the synthetic is merged INTO the carrier.
        let partial: [Message] = [.user("q"),
                                  .assistant(text: "", toolUses: [Self.use("a", "1"), Self.use("b", "2")]),
                                  .toolResults([Self.res("a", "1", "ok")]),
                                  .assistant("done")]
        let fixed = HistoryEditor.fixIncompleteToolCycles(partial)
        XCTAssertEqual(fixed.count, 4, "no extra message — merged")
        XCTAssertEqual(fixed[2].toolResults.map(\.toolUseId), ["1", "2"])
        XCTAssertEqual(fixed[2].toolResults[1].content, HistoryEditor.syntheticResultText)
        XCTAssertEqual(fixed[2].toolResults[1].name, "b")
        XCTAssertTrue(HistoryEditor.validateStructure(fixed).ok)
        // No carrier at all → a new one is inserted right after the assistant message.
        let bare: [Message] = [.user("q"), .assistant(text: "", toolUses: [Self.use("a", "1")]), .user("next")]
        let fixed2 = HistoryEditor.fixIncompleteToolCycles(bare)
        XCTAssertEqual(fixed2.count, 4); XCTAssertEqual(fixed2[2].toolResults.first?.toolUseId, "1"); XCTAssertEqual(fixed2[3].text, "next")
        // Untouched when complete.
        XCTAssertEqual(HistoryEditor.fixIncompleteToolCycles(Array(Self.fixture().prefix(14))), Array(Self.fixture().prefix(14)))
    }

    func testValidateStructure() {
        XCTAssertTrue(HistoryEditor.validateStructure(Array(Self.fixture().prefix(14))).ok)
        let broken = HistoryEditor.validateStructure(Self.fixture())   // the running call is unresolved
        XCTAssertFalse(broken.ok); XCTAssertTrue(broken.error.contains(Self.selfId))
        let adjacent = HistoryEditor.validateStructure([.user("a"), .user("b")])
        XCTAssertTrue(adjacent.ok); XCTAssertEqual(adjacent.warnings.count, 1)
        XCTAssertTrue(HistoryEditor.validateStructure([]).ok)
    }

    func testClearKeepsOnlyTheActiveTurn() throws {
        let m = Self.fixture()
        let out = try HistoryEditor.apply(.init(action: .clear), to: m, selfId: Self.selfId)
        XCTAssertEqual(out.messages, Array(m.suffix(2)))
        XCTAssertEqual(out.edit?.turnsAffected, 4)
        XCTAssertEqual(out.edit?.summary, "The model started its notes over (4 turns) · your conversation is unchanged")
        let again = try HistoryEditor.apply(.init(action: .clear), to: out.messages, selfId: Self.selfId)
        XCTAssertNil(again.edit)
    }

    func testReadOnlyViews() throws {
        let m = Self.fixture()
        let list = try HistoryEditor.apply(.init(action: .list), to: m, selfId: Self.selfId)
        XCTAssertNil(list.edit)
        XCTAssertTrue(list.text.contains("--- turn 0 (msgs 0-3) ---"), list.text)
        XCTAssertTrue(list.text.contains("--- turn ACTIVE (msgs 14-15) ---"), list.text)
        XCTAssertTrue(list.text.contains("toolUse:current_time"), list.text)
        var byRole = HistoryEditor.Request(action: .list); byRole.role = .user
        XCTAssertTrue(try HistoryEditor.apply(byRole, to: m).text.hasPrefix("8 user messages:"))
        let tools = try HistoryEditor.apply(.init(action: .listTools), to: m, selfId: Self.selfId)
        XCTAssertTrue(tools.text.hasPrefix("5 tool calls:"), tools.text)
        XCTAssertTrue(tools.text.contains("⏳ manage_messages 🔒(active)  id=\(Self.selfId)"), tools.text)
        XCTAssertTrue(tools.text.contains("✅ calculator  id=t1a"), tools.text)
        let stats = try HistoryEditor.apply(.init(action: .stats), to: m, selfId: Self.selfId, projectedTokens: 4321)
        XCTAssertTrue(stats.text.contains("Turns: 5 (4 droppable + the active one)"), stats.text)
        XCTAssertTrue(stats.text.contains("Context: ≈4321 tokens (last model call's usage"), stats.text)
        XCTAssertTrue(stats.text.contains("Top tools: calculator(2), current_time(1), http(1), manage_messages(1)"), stats.text)
        XCTAssertTrue(stats.text.contains("Pending toolUse (no result): 1"), stats.text)
        let estimated = try HistoryEditor.apply(.init(action: .stats), to: m)
        XCTAssertTrue(estimated.text.contains("(estimated from shape)"))
        XCTAssertEqual(try HistoryEditor.apply(.init(action: .list), to: []).text, "No messages")
        XCTAssertEqual(try HistoryEditor.apply(.init(action: .listTools), to: [.user("x")]).text, "No tool calls found")
    }

    func testRequestParsingIsLenientForSmallModels() throws {
        XCTAssertEqual(try HistoryEditor.Request(args: ["action": "compact"]).action, .compact)
        XCTAssertEqual(try HistoryEditor.Request(args: ["action": "List Tools"]).action, .listTools)
        XCTAssertEqual(try HistoryEditor.Request(args: ["action": "compress"]).action, .compact)
        XCTAssertEqual(try HistoryEditor.Request(args: ["action": "delete", "turns": "0, 1,2"]).turns, [0, 1, 2])
        XCTAssertEqual(try HistoryEditor.Request(args: ["action": "drop", "turns": [0, 2]]).turns, [0, 2])
        XCTAssertEqual(try HistoryEditor.Request(args: ["action": "drop", "turn": 3]).turns, [3])
        XCTAssertEqual(try HistoryEditor.Request(args: ["action": "compact", "keep": 1]).keepLast, 1)
        XCTAssertEqual(try HistoryEditor.Request(args: ["action": "drop_tools", "tool_ids": "a,b"]).toolIds, ["a", "b"])
        XCTAssertEqual(try HistoryEditor.Request(args: ["action": "drop_tools", "tool": "http"]).toolName, "http")
        XCTAssertEqual(try HistoryEditor.Request(args: ["action": "list", "role": "User"]).role, .user)
        XCTAssertThrowsError(try HistoryEditor.Request(args: [:])) { XCTAssertTrue("\($0)".contains("unknown action"), "\($0)") }
        XCTAssertThrowsError(try HistoryEditor.Request(args: ["action": "fly"]))
    }

    func testSummarize() {
        XCTAssertEqual(HistoryEditor.summarize([.text("hello\nworld")]), "\"hello world\"")
        XCTAssertEqual(HistoryEditor.summarize([.text(String(repeating: "x", count: 100))], maxLength: 10), "\"xxxxxxxxxx…\"")
        XCTAssertEqual(HistoryEditor.summarize([]), "(empty)")
        XCTAssertEqual(HistoryEditor.summarize([.reasoning("r"), .toolUse(Self.use("a", "1")), .toolResult(Self.res("a", "1", "x")), .image(ImageBlock(data: Data(), mime: "image/png"))]), "[reasoning] | toolUse:a | toolResult:a | +1 more")
    }

    // MARK: - through the Agent: the edit is what the NEXT model call sees, the UI gets one marker

    func testManageMessagesCompactIsEffectiveForTheNextModelCallInTheSameTurn() async throws {
        // Turn 1: calculator; turn 2: calculator; turn 3: the model calls manage_messages compact(keep_last:0), then answers.
        let fake = FakeModel(turns: [
            .toolUse([Self.use("calculator", "c1", ["expression": "1+1"])]), .text("2"),
            .toolUse([Self.use("calculator", "c2", ["expression": "2+2"])]), .text("4"),
            .toolUse([Self.use("manage_messages", "mm", ["action": "compact", "keep_last": 0])]), .text("tidy"),
        ])
        let agent = Agent(model: fake, tools: [CalculatorTool(), ManageMessagesTool()], retryStrategy: nil)
        _ = try await agent("1+1"); _ = try await agent("2+2")
        let before = await agent.messages
        XCTAssertEqual(HistoryEditor.allToolCalls(before).count, 2)

        var events: [AgentEvent] = []
        for try await e in agent.stream("the context is long") { events.append(e) }

        // The tool's own result is honest and the model's NEXT prompt (the 6th call) already lacks the old tool blocks.
        let toolResults = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }
        XCTAssertEqual(toolResults.count, 1); XCTAssertEqual(toolResults[0].status, .success)
        XCTAssertTrue(toolResults[0].content.hasPrefix("Compacted 2 turn(s), removed 4 tool blocks"), toolResults[0].content)
        let prompts = await fake.seenPrompts
        XCTAssertEqual(prompts.count, 6)
        XCTAssertEqual(HistoryEditor.allToolCalls(prompts[4]).map(\.name), ["calculator", "calculator"], "the call that asked for the compaction still saw everything")
        XCTAssertEqual(HistoryEditor.allToolCalls(prompts[5]).map(\.name), ["manage_messages"], "the next call sees only the active turn's tool cycle")
        XCTAssertEqual(prompts[5].compactMap { $0.role == .user && !$0.hasToolResult ? $0.text : nil }, ["1+1", "2+2", "the context is long"], "every user query's text stays")
        XCTAssertEqual(prompts[5].compactMap { $0.role == .assistant ? $0.text : nil }.filter { !$0.isEmpty }, ["2", "4"])
        XCTAssertTrue(HistoryEditor.validateStructure(prompts[5]).ok)

        // Exactly one marker event, after the tool ran and before its result; the transcript folds it into a quiet note.
        let edits = events.compactMap { if case .historyEdited(let e) = $0 { return e }; return nil }
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0], HistoryEdit(action: .compact, turnsAffected: 2, toolBlocksRemoved: 4, messagesBefore: 10, messagesAfter: 6))
        let editIdx = events.firstIndex { if case .historyEdited = $0 { return true }; return false }!
        let resultIdx = events.firstIndex { if case .toolResult = $0 { return true }; return false }!
        XCTAssertLessThan(editIdx, resultIdx)
        var transcript = Transcript()
        transcript.user("the context is long")
        for e in events { transcript.apply(e) }
        XCTAssertTrue(transcript.items.contains { $0.kind == .note("The model tidied 2 turns of notes · your conversation is unchanged") }, "\(transcript.items.map(\.kind))")
        XCTAssertEqual(transcript.items.filter { if case .note = $0.kind { return true }; return false }.count, 1)

        // The live history ends the turn with the compacted shape + the final answer.
        let after = await agent.messages
        XCTAssertEqual(after.count, 6 + 1 + 1)   // 6 at the model call + toolResult carrier + "tidy"
        XCTAssertTrue(HistoryEditor.validateStructure(after).ok)
    }

    func testManageMessagesReadActionsDoNotEmitAMarkerAndStatsUsesTheMeasuredBaseline() async throws {
        let fake = FakeModel(turns: [.text("hi"), .toolUse([Self.use("manage_messages", "s", ["action": "stats"])]), .text("ok")])
        let agent = Agent(model: fake, tools: [ManageMessagesTool()], retryStrategy: nil)
        _ = try await agent("hello")
        var events: [AgentEvent] = []
        for try await e in agent.stream("how big?") { events.append(e) }
        XCTAssertFalse(events.contains { if case .historyEdited = $0 { return true }; return false })
        let r = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }.first!
        XCTAssertEqual(r.status, .success)
        XCTAssertTrue(r.content.contains("Turns: 2 (1 droppable + the active one)"), r.content)
        XCTAssertTrue(r.content.contains("last model call's usage"), "FakeModel reports promptTokens, so the agent has a measured baseline: \(r.content)")
    }

    func testManageMessagesOutsideAnAgentIsHonest() async {
        do { _ = try await ManageMessagesTool().call(["action": "compact"]); XCTFail("no context → error") }
        catch { XCTAssertTrue("\(error)".contains("no live agent"), "\(error)") }
    }

    func testBadRequestReachesTheModelAsAnErrorResultAndChangesNothing() async throws {
        let fake = FakeModel(turns: [.text("hi"), .toolUse([Self.use("manage_messages", "d", ["action": "drop", "turns": [7]])]), .text("ok")])
        let agent = Agent(model: fake, tools: [ManageMessagesTool()], retryStrategy: nil)
        _ = try await agent("hello")
        let before = await agent.messages
        var events: [AgentEvent] = []
        for try await e in agent.stream("drop something") { events.append(e) }
        let r = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }.first!
        XCTAssertEqual(r.status, .error)
        XCTAssertTrue(r.promptContent.hasPrefix("ERROR: manage_messages: no such turn(s): 7"), r.promptContent)
        XCTAssertFalse(events.contains { if case .historyEdited = $0 { return true }; return false })
        let after = await agent.messages
        XCTAssertEqual(Array(after.prefix(before.count)), before, "nothing before the active turn moved")
    }
}
