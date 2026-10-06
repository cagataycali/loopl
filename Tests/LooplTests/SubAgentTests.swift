import XCTest
@testable import Loopl

/// Routes `stream` to one of two scripted models by system prompt — the parent and its children share ONE
/// `Model` in production (and one `ModelGate`); here each side gets its own script so the order of calls does
/// not matter to the assertions.
actor SplitModel: Model {
    nonisolated let kind: RuntimeKind = .mlx
    let parent: FakeModel
    let child: FakeModel
    let childMarker: String
    private(set) var loadedModelId: String? = "split"
    private(set) var params = GenerationParams()
    private(set) var calls: [String] = []       // "parent" / "child" in call order
    init(parent: FakeModel, child: FakeModel, childMarker: String = "CHILD") { self.parent = parent; self.child = child; self.childMarker = childMarker }
    nonisolated static func availability() -> RuntimeAvailability { .ok }
    func updateConfig(_ params: GenerationParams) { self.params = params }
    func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {}
    func unload() async {}
    private func record(_ who: String) { calls.append(who) }
    nonisolated func stream(_ messages: [Message], toolSpecs: [ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
        let isChild = systemPrompt?.contains(childMarker) == true
        Task { await self.record(isChild ? "child" : "parent") }
        return (isChild ? child : parent).stream(messages, toolSpecs: toolSpecs, systemPrompt: systemPrompt)
    }
}

final class SubAgentTests: XCTestCase {
    static let childSystem = "CHILD fetcher. Fetch the page and report the number."

    /// A parent agent with `use_agent` + a probe tool, sharing `model` with the hub.
    func makeParent(model: any Model, hub: SubAgentHub, extraTools: [any Tool] = []) -> (Agent, ModelGate) {
        let gate = ModelGate()
        let probe = ClosureTool(name: "probe", description: "returns 42", parameters: ToolSchema.object([:])) { _ in "42" }
        let available: [any Tool] = [probe, CalculatorTool()] + extraTools
        let tool = UseAgentTool(hub: hub) { SubAgentContext(model: model, gate: gate, availableTools: available, approvalTimeout: 2) }
        let parent = Agent(model: model, tools: available + [tool], systemPrompt: "parent")
        return (parent, gate)
    }

    func collect(_ agent: Agent, _ prompt: String) async throws -> [AgentEvent] {
        var out: [AgentEvent] = []
        for try await e in agent.stream(prompt) { out.append(e) }
        return out
    }

    // MARK: inline

    func testInlineChildResultReachesTheParent() async throws {
        let parentScript = FakeModel(turns: [
            .toolUse([ToolUse(toolUseId: "t1", name: "use_agent", input: [
                "action": "run", "system_prompt": .string(Self.childSystem), "input": "what is the number?", "tools": ["probe"]])]),
            .text("The child found 42."),
        ])
        let childScript = FakeModel(turns: [
            .toolUse([ToolUse(toolUseId: "c1", name: "probe", input: [:])]),
            .text("The number is 42."),
        ])
        let model = SplitModel(parent: parentScript, child: childScript)
        let hub = SubAgentHub()
        let (parent, gate) = makeParent(model: model, hub: hub)
        await parent.setModelGate(gate)

        let events = try await collect(parent, "ask a helper")
        // Parent's use_agent result carries the child's answer.
        let results = events.compactMap { if case .toolResult(let r) = $0, r.name == "use_agent" { return r }; return nil }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].content.contains("\"status\":\"done\""), results[0].content)
        XCTAssertTrue(results[0].content.contains("The number is 42."), results[0].content)
        XCTAssertFalse(results[0].content.contains("pending"), results[0].content)
        // Child events rode the parent's stream, nested.
        let started = events.compactMap { if case .childStarted(let i) = $0 { return i }; return nil }
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started[0].parentToolUseId, "t1")
        XCTAssertEqual(started[0].tools, ["probe"])
        XCTAssertEqual(started[0].name, "CHILD fetcher")
        let childTools = events.compactMap { if case .child(let id, .toolStarted(let u)) = $0 { return (id, u.name) }; return nil }
        XCTAssertEqual(childTools.map(\.1), ["probe"])
        XCTAssertEqual(childTools.first?.0, started[0].id)
        let statuses = events.compactMap { if case .childStatus(_, let s) = $0 { return s }; return nil }
        XCTAssertEqual(statuses, [.queued, .running, .done])
        // Order: toolStarted(use_agent) < childStarted < child events < toolResult(use_agent).
        let iStart = events.firstIndex { if case .toolStarted(let u) = $0 { return u.name == "use_agent" }; return false }!
        let iChild = events.firstIndex { if case .childStarted = $0 { return true }; return false }!
        let iRes = events.firstIndex { if case .toolResult(let r) = $0 { return r.name == "use_agent" }; return false }!
        XCTAssertLessThan(iStart, iChild); XCTAssertLessThan(iChild, iRes)
        // The parent used the result.
        XCTAssertEqual(events.compactMap { if case .result(let r) = $0 { return r.text }; return nil }, ["The child found 42."])
        // The child's own messages never leaked into the parent's history.
        let msgs = await parent.messages
        XCTAssertFalse(msgs.contains { $0.text.contains("The number is 42.") && $0.role == .assistant })
        // Envelope is queryable afterwards.
        let env = await hub.envelope(started[0].id)
        XCTAssertEqual(env?.status, .done); XCTAssertEqual(env?.toolCalls, 1)

        // Transcript nests the child under the parent's tool row.
        var t = Transcript(); t.user("ask a helper")
        for e in events { t.apply(e) }
        let agents = t.agents
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].status, .done)
        XCTAssertEqual(agents[0].resultText, "The number is 42.")
        XCTAssertTrue(agents[0].transcript.items.contains { if case .toolUse(let u, let r) = $0.kind { return u.name == "probe" && r?.content == "42" }; return false })
        let parentRow = t.items.firstIndex { if case .toolUse(let u, _) = $0.kind { return u.toolUseId == "t1" }; return false }!
        XCTAssertEqual(t.agentIndex(agents[0].info.id), parentRow + 1)
        XCTAssertFalse(t.isRunning)
    }

    // MARK: background + wake

    func testBackgroundChildReturnsPendingAndWakes() async throws {
        let parentScript = FakeModel(turns: [
            .toolUse([ToolUse(toolUseId: "t1", name: "use_agent", input: [
                "action": "run", "system_prompt": .string(Self.childSystem), "input": "slow task", "tools": ["probe"], "wait": false])]),
            .text("Started it in the background."),
        ])
        let childScript = FakeModel(turns: [.text("background done 7")], delayPerChunkNs: 20_000_000)
        let model = SplitModel(parent: parentScript, child: childScript)
        let hub = SubAgentHub()
        let woke = expectation(description: "wake")
        let box = SABox<SubAgentEnvelope>()
        await hub.setOnFinished { env in box.value = env; woke.fulfill() }
        let (parent, gate) = makeParent(model: model, hub: hub)
        await parent.setModelGate(gate)

        // Host side: the detached stream carries the child's later events.
        let detached = hub.detachedEvents()
        let collector = Task { var out: [AgentEvent] = []; for await e in detached { out.append(e); if case .childStatus(_, let s) = e, s.isFinished { break } }; return out }

        let events = try await collect(parent, "do a slow thing")
        let res = events.compactMap { if case .toolResult(let r) = $0, r.name == "use_agent" { return r.content }; return nil }
        XCTAssertEqual(res.count, 1)
        XCTAssertTrue(res[0].contains("\"pending\":true"), res[0])
        XCTAssertTrue(res[0].contains("[use_agent agent_"), res[0])
        let info = events.compactMap { if case .childStarted(let i) = $0 { return i }; return nil }.first!
        XCTAssertEqual(events.compactMap { if case .result(let r) = $0 { return r.text }; return nil }, ["Started it in the background."])

        await fulfillment(of: [woke], timeout: 5)
        let env = box.value!
        XCTAssertEqual(env.id, info.id); XCTAssertEqual(env.status, .done); XCTAssertEqual(env.result, "background done 7")
        XCTAssertTrue(env.info.background)
        let late = await collector.value
        XCTAssertTrue(events.contains { if case .childStatus(_, .background) = $0 { return true }; return false }, "hand-off rides the parent's stream")
        XCTAssertTrue(late.contains { if case .child(_, .result) = $0 { return true }; return false })
        XCTAssertTrue(late.contains { if case .childStatus(_, .done) = $0 { return true }; return false })

        // Fold both halves into one transcript: the card ends "done" with the child's text.
        var t = Transcript(); t.user("do a slow thing")
        for e in events { t.apply(e) }
        XCTAssertEqual(t.agents.first?.status, .background)
        for e in late { t.apply(e) }
        XCTAssertEqual(t.agents.first?.status, .done)
        XCTAssertEqual(t.agents.first?.resultText, "background done 7")

        // The wake prompt names the id and says no human typed it.
        let wake = SubAgentWake.prompt(for: env)
        XCTAssertTrue(wake.hasPrefix("[use_agent \(env.id) finished]"))
        XCTAssertTrue(wake.contains("background done 7") && wake.contains("No human typed this"))
        // result by id afterwards
        let tool = UseAgentTool(hub: hub) { nil }
        let out = try await tool.call(["action": "result", "id": .string(env.id)])
        XCTAssertTrue(out.contains("background done 7"))
    }

    // MARK: refusals

    func testDepthOneAndUnknownToolsAreRefusedWithASentence() async throws {
        let hub = SubAgentHub()
        let model = FakeModel(turns: [])
        let gate = ModelGate()
        let tool = UseAgentTool(hub: hub) { SubAgentContext(model: model, gate: gate, availableTools: [CalculatorTool(), UseAgentTool(hub: hub) { nil }]) }
        do { _ = try await tool.call(["action": "run", "input": "x", "tools": ["use_agent"]]); XCTFail("spawned") }
        catch let e as ToolError { XCTAssertTrue(e.message.contains("depth 1"), e.message) }
        do { _ = try await tool.call(["action": "run", "input": "x", "tools": ["flashlight"]]); XCTFail("spawned") }
        catch let e as ToolError { XCTAssertTrue(e.message.contains("unknown tool 'flashlight'") && e.message.contains("calculator"), e.message) }
        do { _ = try await tool.call(["action": "run", "tools": ["calculator"]]); XCTFail("spawned") }
        catch let e as ToolError { XCTAssertTrue(e.message.contains("needs input"), e.message) }
        do { _ = try await tool.call(["action": "status"]); XCTFail("answered") }
        catch let e as ToolError { XCTAssertTrue(e.message.contains("needs id"), e.message) }
        let missing = try? await tool.call(["action": "status", "id": "agent_nope"])
        XCTAssertNil(missing)
        let n = await hub.list().count
        XCTAssertEqual(n, 0)
    }

    // MARK: cap + queue + stop

    func testFourthChildQueuesAndStopEndsIt() async throws {
        let hub = SubAgentHub()
        let model = FakeModel(turns: [.hang(after: 1), .hang(after: 1), .hang(after: 1), .text("fourth")])
        let gate = ModelGate()
        let ctx = SubAgentContext(model: model, gate: gate, availableTools: [])
        var ids: [String] = []
        for i in 0..<4 { ids.append(await hub.spawn(systemPrompt: "s\(i)", input: "go", tools: [], background: true, context: ctx, sink: nil)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let statuses = await hub.list().map(\.status)
        XCTAssertEqual(statuses.filter { $0 == .background }.count, 3, "\(statuses)")
        XCTAssertEqual(statuses.last, .queued)
        // Stop one running child → the queued one takes the slot (but the ONE model gate is still held by a hung
        // sibling, so it waits its turn — children queue on the weights, they never interleave).
        let stopped = await hub.stop(ids[0])
        XCTAssertTrue(stopped)
        try await Task.sleep(nanoseconds: 200_000_000)
        var after = await hub.list()
        XCTAssertEqual(after[0].status, .stopped)
        XCTAssertEqual(after[3].status, .background, "\(after.map(\.status))")
        XCTAssertNil(after[3].result)
        // Stop the two hung ones → the gate frees → the fourth generates and finishes.
        _ = await hub.stop(ids[1]); _ = await hub.stop(ids[2])
        try await Task.sleep(nanoseconds: 400_000_000)
        after = await hub.list()
        XCTAssertEqual(after.map(\.status), [.stopped, .stopped, .stopped, .done])
        XCTAssertEqual(after[3].result, "fourth")
        await hub.stopAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        let running = await hub.running
        XCTAssertTrue(running.isEmpty)
        XCTAssertTrue(ids.allSatisfy(SubAgentHub.isValidId))
    }

    // MARK: gate

    func testModelGateIsFIFOAndExclusive() async throws {
        let gate = ModelGate()
        await gate.acquire()
        XCTAssertTrue(gate.isBusy)
        let order = SABox<[Int]>(); order.value = []
        let t1 = Task { await gate.acquire(); order.value!.append(1); gate.release() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let t2 = Task { await gate.acquire(); order.value!.append(2); gate.release() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(gate.waiting, 2)
        XCTAssertEqual(order.value, [])
        gate.release()
        _ = await (t1.value, t2.value)
        XCTAssertEqual(order.value, [1, 2])
        XCTAssertFalse(gate.isBusy)
    }

    func testNameFromSystemPrompt() {
        XCTAssertEqual(SubAgentInfo.name(from: "", ordinal: 2), "agent 2")
        XCTAssertEqual(SubAgentInfo.name(from: "Weather scout. You look up forecasts.", ordinal: 1), "Weather scout")
        XCTAssertEqual(SubAgentInfo.name(from: String(repeating: "x", count: 80), ordinal: 1).count, 40)
    }
}

final class SABox<T>: @unchecked Sendable { var value: T?; init() {} }
