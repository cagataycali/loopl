import XCTest
@testable import Loopl

/// "Hold a message and edit it": truncating the visible thread, rebuilding the model history
/// from what is kept, and regenerating from a truncated history with a fresh Agent.
final class TranscriptEditingTests: XCTestCase {

    /// user → (text + tool) → tool result → answer → user → answer
    private func sample() -> Transcript {
        var t = Transcript()
        t.user("What time is it in Istanbul?")
        t.apply(.startEventLoop(cycle: 1))
        t.apply(.text("Let me check."))
        let c = ToolUse(toolUseId: "t1", name: "current_time", input: ["timezone": .string("Europe/Istanbul")])
        t.apply(.modelMessage(.assistant(text: "Let me check.", toolUses: [c])))
        t.apply(.toolStarted(c))
        t.apply(.toolResult(ToolResult(toolUseId: "t1", name: "current_time", content: "06:14", durationMs: 1)))
        t.apply(.startEventLoop(cycle: 2))
        t.apply(.text("It's 06:14."))
        t.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant("It's 06:14."), metrics: EventLoopMetrics())))
        t.user("And in Tokyo?")
        t.apply(.startEventLoop(cycle: 1))
        t.apply(.text("12:14."))
        t.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant("12:14."), metrics: EventLoopMetrics())))
        return t
    }

    private func userItems(_ t: Transcript) -> [TranscriptItem] { t.items.filter { if case .user = $0.kind { return true }; return false } }

    func testTruncateBeforeDropsTheItemAndEverythingAfter() {
        let t = sample()
        let second = userItems(t)[1]
        let cut = t.truncated(before: second.id)
        XCTAssertEqual(cut.items.count, 4)   // user, assistant, tool, assistant
        XCTAssertFalse(cut.items.contains { $0.id == second.id })
        XCTAssertFalse(cut.isRunning)
        XCTAssertNil(cut.lastResult)
        XCTAssertEqual(cut.metrics, t.metrics, "metrics describe what was spent and stay")
    }

    func testTruncateThroughKeepsTheItem() {
        let t = sample()
        let first = userItems(t)[0]
        let cut = t.truncated(through: first.id)
        XCTAssertEqual(cut.items.count, 1)
        XCTAssertEqual(cut.items.first?.id, first.id)
    }

    func testTruncateUnknownIdIsANoop() {
        let t = sample()
        XCTAssertEqual(t.truncated(before: UUID()), t)
        XCTAssertEqual(t.truncated(through: UUID()), t)
    }

    func testTruncationResetsStreamingCursorSoNewTextStartsANewRow() {
        var t = Transcript()
        t.user("hi")
        t.apply(.startEventLoop(cycle: 1))
        t.apply(.text("partial answer"))                     // streaming row open (cursor points at it)
        var cut = t.truncated(before: t.items[1].id)         // cut the streaming row away → [user]
        cut.apply(.text("new"))                              // a stale cursor would index past the end
        XCTAssertEqual(cut.items.count, 2)
        if case .assistant(let s) = cut.items[1].kind { XCTAssertEqual(s, "new") } else { XCTFail("expected a fresh assistant row") }
    }

    func testUserTurnBeforeFindsTheOwningUserRow() {
        let t = sample()
        let users = userItems(t)
        // the last assistant row belongs to the second user turn
        XCTAssertEqual(t.userTurn(before: t.items.last!.id)?.id, users[1].id)
        // the tool row belongs to the first
        XCTAssertEqual(t.userTurn(before: t.items[2].id)?.id, users[0].id)
        // a user row owns itself
        XCTAssertEqual(t.userTurn(before: users[0].id)?.id, users[0].id)
        XCTAssertNil(t.userTurn(before: UUID()))
    }

    func testMessagesRebuildStrandsShapeFromVisibleItems() {
        let t = sample()
        let m = t.messages
        XCTAssertEqual(m.map(\.role), [.user, .assistant, .user, .assistant, .user, .assistant])
        XCTAssertEqual(m[0].text, "What time is it in Istanbul?")
        XCTAssertEqual(m[1].text, "Let me check.")
        XCTAssertEqual(m[1].toolUses.map(\.toolUseId), ["t1"])
        XCTAssertEqual(m[2].toolResults.map(\.content), ["06:14"])
        XCTAssertEqual(m[3].text, "It's 06:14.")
        XCTAssertEqual(m[4].text, "And in Tokyo?")
        XCTAssertEqual(m[5].text, "12:14.")
    }

    func testMessagesSkipNotesApprovalsReasoningAndUnfinishedTools() {
        var t = Transcript()
        t.user("post it")
        t.note("Switched to Qwen")
        t.apply(.startEventLoop(cycle: 1))
        t.apply(.reasoning("thinking…"))
        let c = ToolUse(toolUseId: "p1", name: "http", input: ["url": .string("https://x.y")])
        t.apply(.toolStarted(c))                              // no result ever arrives
        t.user("again")
        t.apply(.startEventLoop(cycle: 1))
        t.apply(.text("done"))
        let m = t.messages
        XCTAssertEqual(m.map(\.role), [.user, .user, .assistant])
        XCTAssertTrue(m.allSatisfy { $0.toolUses.isEmpty && $0.toolResults.isEmpty })
        XCTAssertEqual(m.last?.text, "done")
    }

    func testMessagesNeverEndOnABareUserTurn() {
        var t = Transcript()
        t.user("first"); t.apply(.startEventLoop(cycle: 1)); t.apply(.text("a"))
        t.apply(.result(AgentResult(stopReason: .endTurn, message: .assistant("a"), metrics: EventLoopMetrics())))
        t.user("dangling")                                    // the turn being edited, still in the kept half
        let m = t.messages
        XCTAssertEqual(m.map(\.role), [.user, .assistant], "the edited turn is appended by the agent call, not the history")
    }

    func testMessagesCarryUserImages() {
        var t = Transcript()
        let img = ImageBlock(data: Data([0x89, 0x50]), mime: "image/png", width: 2, height: 2, alt: "px")
        t.user("look", images: [img])
        t.apply(.startEventLoop(cycle: 1)); t.apply(.text("a dot"))
        let m = t.messages
        XCTAssertEqual(m[0].content.count, 2)
        if case .image(let b) = m[0].content[1] { XCTAssertEqual(b.alt, "px") } else { XCTFail("image block missing") }
    }

    /// The Engine's regenerate path, at SDK level: truncate → fresh agent on `messages` → stream the edited turn.
    func testRegenerateFromTruncatedHistoryReinvokesWithKeptContextOnly() async throws {
        let t = sample()
        let second = userItems(t)[1]
        var kept = t.truncated(before: second.id)
        let fake = FakeModel(turns: [.text("13:14 in Tokyo.")])
        let agent = Agent(model: fake, tools: [], retryStrategy: nil)
        await agent.setMessages(kept.messages)
        kept.user("And in Tokyo, precisely?")
        for try await e in agent.stream([.user("And in Tokyo, precisely?")]) { kept.apply(e) }

        let prompts = await fake.seenPrompts
        XCTAssertEqual(prompts.count, 1)
        let sent = prompts[0]
        // kept history (4 messages: user, assistant+toolUse, toolResult, assistant) + the edited user turn
        XCTAssertEqual(sent.map(\.role), [.user, .assistant, .user, .assistant, .user])
        XCTAssertEqual(sent.last?.text, "And in Tokyo, precisely?")
        XCTAssertFalse(sent.contains { $0.text == "And in Tokyo?" }, "the replaced turn must not reach the model")
        XCTAssertFalse(kept.items.contains { if case .assistant("12:14.") = $0.kind { return true }; return false })
        XCTAssertEqual(kept.items.count, 6)
        if case .assistant(let s) = kept.items.last!.kind { XCTAssertEqual(s, "13:14 in Tokyo.") } else { XCTFail() }
        XCTAssertFalse(kept.isRunning)
    }
}
