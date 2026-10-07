import XCTest
@testable import Loopl

/// `system_prompt` (Phase 6 F): the agent changes its OWN system prompt — in force for the NEXT model call of the same
/// turn, persisted through the host's store, every write behind an approval card with an old → new preview.
final class SystemPromptToolTests: XCTestCase {
    static func use(_ name: String, _ id: String, _ input: [String: JSONValue] = [:]) -> ToolUse { ToolUse(toolUseId: id, name: name, input: input) }
    static let base = "You are loopl. Answer concisely."
    static let rule = "Always answer in Turkish."

    func testAppendIsEffectiveForTheNextModelCallOfTheSameTurnAndPersists() async throws {
        let store = InMemorySystemPromptStore(prompt: Self.base)
        let fake = FakeModel(turns: [
            .toolUse([Self.use("system_prompt", "sp1", ["action": "append", "text": .string(Self.rule)])]), .text("Tamam."),
        ])
        let agent = Agent(model: fake, tools: [SystemPromptTool(store: store)], systemPrompt: Self.base, retryStrategy: nil)
        var events: [AgentEvent] = []
        for try await e in agent.stream("from now on always answer in Turkish") {
            events.append(e)
            if case .approvalRequested(let req) = e { Task { await agent.resolve(approval: req.id, ApprovalDecision.approve) } }
        }
        let systems = await fake.seenSystemPrompts
        XCTAssertEqual(systems.count, 2)
        XCTAssertEqual(systems[0], Self.base, "the call that asked for the change saw the old prompt")
        XCTAssertEqual(systems[1], Self.base + "\n\n" + Self.rule, "the NEXT model call of the same turn already runs on the new prompt")
        XCTAssertEqual(store.read(), Self.base + "\n\n" + Self.rule, "persisted for every later conversation")
        XCTAssertEqual(store.history.map(\.action), [.append])

        let results = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }
        XCTAssertEqual(results.count, 1); XCTAssertEqual(results[0].status, .success)
        XCTAssertTrue(results[0].content.hasPrefix("System prompt extended (32 → 59 chars)"), results[0].content)

        // One marker event, between the tool running and its result; the transcript folds it into a quiet note.
        let changes = events.compactMap { if case .systemPromptChanged(let c) = $0 { return c }; return nil }
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(changes[0].action, .append); XCTAssertEqual(changes[0].before, Self.base)
        let markIdx = events.firstIndex { if case .systemPromptChanged = $0 { return true }; return false }!
        let resultIdx = events.firstIndex { if case .toolResult = $0 { return true }; return false }!
        XCTAssertLessThan(markIdx, resultIdx)
        var transcript = Transcript(); transcript.user("x"); for e in events { transcript.apply(e) }
        XCTAssertTrue(transcript.items.contains { $0.kind == .note("system prompt extended by the agent · revert in Settings › System prompt") }, "\(transcript.items.map(\.kind))")

        // The approval card led with the right words and a diff-style preview.
        let req = events.compactMap { if case .approvalRequested(let r) = $0 { return r }; return nil }.first!
        XCTAssertEqual(req.title, "Add to my instructions"); XCTAssertEqual(req.risk, .medium)
        XCTAssertEqual(req.bodyPreview, "  …32 chars kept\n+ Always answer in Turkish.")
    }

    func testDeniedChangeIsHonestAndChangesNothing() async throws {
        let store = InMemorySystemPromptStore(prompt: Self.base)
        let fake = FakeModel(turns: [.toolUse([Self.use("system_prompt", "sp", ["action": "set", "text": "Be rude."])]), .text("ok")])
        let agent = Agent(model: fake, tools: [SystemPromptTool(store: store)], systemPrompt: Self.base, retryStrategy: nil)
        var events: [AgentEvent] = []
        for try await e in agent.stream("replace your instructions") {
            events.append(e)
            if case .approvalRequested(let req) = e { Task { await agent.resolve(approval: req.id, ApprovalDecision.deny(reason: "no")) } }
        }
        XCTAssertEqual(store.read(), Self.base); XCTAssertTrue(store.history.isEmpty)
        let systems = await fake.seenSystemPrompts
        XCTAssertEqual(systems, [Self.base, Self.base])
        let results = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }
        XCTAssertEqual(results.first?.status, .error, "\(results)")
        XCTAssertFalse(events.contains { if case .systemPromptChanged = $0 { return true }; return false })
    }

    func testGetReadsWithoutApprovalAndNamesTheOrigin() async throws {
        let store = InMemorySystemPromptStore(prompt: "Custom.", defaultPrompt: Self.base)
        let tool = SystemPromptTool(store: store)
        XCTAssertNil(tool.requiresApproval(for: ["action": "get"]))
        let got = try await tool.call(["action": "get"])
        XCTAssertEqual(got, "Your system prompt (edited by the user, 7 chars):\nCustom.")
        let def = try await SystemPromptTool(store: InMemorySystemPromptStore(prompt: Self.base)).call(["action": "GET"])
        XCTAssertEqual(def, "Your system prompt (default, 32 chars):\n\(Self.base)")
    }

    func testResetAndSetPreviewsAndNoops() async throws {
        let store = InMemorySystemPromptStore(prompt: "Custom.", defaultPrompt: Self.base)
        let tool = SystemPromptTool(store: store)
        let reset = tool.requiresApproval(for: ["action": "reset"])
        XCTAssertEqual(reset?.title, "Reset my instructions"); XCTAssertEqual(reset?.bodyPreview, "− Custom.\n+ \(Self.base)")
        let r1 = try await tool.call(["action": "reset"])
        XCTAssertEqual(r1, "System prompt reset to the app default (32 chars). It applies from your next step and to every new conversation; the user can revert it in Settings › System prompt.")
        XCTAssertEqual(store.read(), Self.base)
        // Already the default / already present / same text → no card, honest no-op.
        XCTAssertNil(tool.requiresApproval(for: ["action": "reset"]))
        let r2 = try await tool.call(["action": "reset"])
        XCTAssertEqual(r2, "your system prompt is already the default — nothing changed.")
        XCTAssertNil(tool.requiresApproval(for: ["action": "append", "text": "answer CONCISELY."]))
        let r3 = try await tool.call(["action": "append", "text": "answer CONCISELY."])
        XCTAssertEqual(r3, "already in your instructions — nothing changed.")
        let r4 = try await tool.call(["action": "set", "text": .string(Self.base)])
        XCTAssertEqual(r4, "already your system prompt — nothing changed.")
        // set: a real replacement, preview truncated to the limit.
        let long = String(repeating: "x", count: 1000)
        let set = tool.requiresApproval(for: ["action": "set", "prompt": .string(long)])     // `prompt` accepted as the text key (small models)
        XCTAssertEqual(set?.title, "Replace my instructions")
        XCTAssertEqual(set?.bodyPreview?.components(separatedBy: "\n").last?.count, 2 + SystemPromptTool.previewLimit)
        XCTAssertTrue(set!.bodyPreview!.hasSuffix("…"))
        XCTAssertEqual(store.history.map(\.action), [.reset])
    }

    func testBadInputReachesTheModelAsAnError() async {
        let tool = SystemPromptTool(store: InMemorySystemPromptStore(prompt: Self.base))
        for args in [["action": "set"], ["action": "append", "text": "  "], ["action": "delete"]] as [[String: JSONValue]] {
            do { _ = try await tool.call(args); XCTFail("expected an error for \(args)") } catch { XCTAssertTrue(error is ToolError) }
            XCTAssertNil(tool.requiresApproval(for: args), "no card for a request the tool refuses")
        }
    }
}
