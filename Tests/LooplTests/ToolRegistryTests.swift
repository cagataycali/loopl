import XCTest
import Loopl

/// Phase 6, lane A — `ToolRegistry` + `manage_tools` + the one thing the owner stressed: a mount made INSIDE a turn
/// is in the tool specs of the very next model request of that same turn (`Agent.syncTools` runs before every
/// request), so the model can use the tool it just mounted without a new user message.
final class ToolRegistryTests: XCTestCase {
    func use(_ name: String, _ args: [String: JSONValue] = [:], id: String = ToolUse.makeId()) -> ToolUse {
        ToolUse(toolUseId: id, name: name, input: args)
    }

    // MARK: registry

    func testCatalogOrderMountUnmountPinned() async {
        let r = ToolRegistry(catalog: [CurrentTimeTool(), CalculatorTool(), HttpTool()], mounted: ["calculator"], pinned: ["current_time"])
        var names = await r.mountedNames
        XCTAssertEqual(names, ["current_time", "calculator"], "pinned is always mounted; mounted set honoured; catalog order")
        let c = await r.mount(["http", "calculator", "nope"])
        XCTAssertEqual(c.changed, ["http"]); XCTAssertEqual(c.unchanged, ["calculator"]); XCTAssertEqual(c.unknown, ["nope"])
        names = await r.mountedNames
        XCTAssertEqual(names, ["current_time", "calculator", "http"], "mount order = catalog order, not call order")
        let u = await r.unmount(["current_time", "http"])
        XCTAssertEqual(u.pinned, ["current_time"]); XCTAssertEqual(u.changed, ["http"])
        let v1 = await r.version
        _ = await r.unmount(["http"])                       // no-op
        let v2 = await r.version
        XCTAssertEqual(v1, v2, "a no-op does not bump the version")
    }

    func testUnavailableToolIsListedNeverMounted() async {
        let r = ToolRegistry(catalog: [CalculatorTool()])
        await r.register(ClosureTool(name: "flashlight", description: "torch") { _ in "" }, source: .app, mounted: true, available: false, reason: "No torch on this device.")
        let c = await r.mount(["flashlight"])
        XCTAssertEqual(c.unavailable.map(\.0), ["flashlight"])
        let list = await r.list()
        XCTAssertEqual(list.map(\.name), ["calculator", "flashlight"])
        XCTAssertEqual(list[1].available, false); XCTAssertEqual(list[1].mounted, false)
        let names = await r.mountedNames
        XCTAssertEqual(names, ["calculator"])
    }

    func testSetMountedKeepsPinnedAndUnregisterRefusesAppTools() async {
        let r = ToolRegistry(catalog: [CurrentTimeTool(), CalculatorTool()], pinned: ["current_time"])
        await r.setMounted([])
        var names = await r.mountedNames
        XCTAssertEqual(names, ["current_time"])
        await r.register(ClosureTool(name: "mine", description: "created") { _ in "" }, source: .created)
        names = await r.mountedNames
        XCTAssertEqual(names, ["current_time", "mine"], "a tool registered at runtime is mounted — the point of registering it is to use it")
        let refused = await r.unregister("calculator"), ok = await r.unregister("mine")
        XCTAssertFalse(refused); XCTAssertTrue(ok)
        let all = await r.names
        XCTAssertEqual(all, ["current_time", "calculator"])
    }

    func testObserverSeesEveryMountedChange() async {
        let r = ToolRegistry(catalog: [CalculatorTool(), HttpTool()], mounted: [])
        let seen = Seen()
        await r.observe { seen.add($0) }
        _ = await r.mount(["http"]); _ = await r.mount(["calculator"]); _ = await r.unmount(["http"])
        XCTAssertEqual(seen.all, [["http"], ["calculator", "http"], ["calculator"]])
    }
    final class Seen: @unchecked Sendable { var all: [[String]] = []; let lock = NSLock(); func add(_ n: [String]) { lock.lock(); all.append(n); lock.unlock() } }

    // MARK: the agent reads the registry at request time

    /// THE proof (unit half; ManageToolsMeasurement is the real-model half). Turn: user asks → model (no http
    /// offered) calls manage_tools mount http → the NEXT request of the SAME turn carries http in its specs → the model
    /// calls http → answer. Three model calls, one user message.
    func testMountMidTurnIsOfferedOnTheNextModelCall() async throws {
        let registry = ToolRegistry(catalog: [CalculatorTool(), ClosureTool(name: "http", description: "fetch a URL", parameters: ToolSchema.object(["url": ToolSchema.string("url")])) { args in
            "fetched \(args["url"]?.stringValue ?? "?")"
        }], mounted: ["calculator"])
        let model = FakeModel(turns: [
            .toolUse([use(ManageToolsTool.toolName, ["action": "mount", "names": ["http"]], id: "m1")]),
            .toolUse([use("http", ["url": "https://loopl.dev"], id: "h1")]),
            .text("done"),
        ])
        let agent = Agent(model: model, tools: [ManageToolsTool(registry: registry)], systemPrompt: "s", retryStrategy: nil, registry: registry)
        var events: [AgentEvent] = []
        for try await e in agent.stream("fetch loopl.dev") { events.append(e) }

        let specs = await model.seenToolSpecs.map { $0.map(\.name) }
        XCTAssertEqual(specs.count, 3)
        XCTAssertEqual(specs[0], ["calculator", "manage_tools"], "request 1: the defaults + the pinned manage_tools; no http")
        XCTAssertEqual(specs[1], ["calculator", "http", "manage_tools"], "request 2 — SAME turn — offers http: the mount was effective immediately")
        XCTAssertEqual(specs[2], specs[1])

        let results = events.compactMap { if case .toolResult(let r) = $0 { return r }; return nil }
        XCTAssertEqual(results.map(\.name), ["manage_tools", "http"])
        XCTAssertFalse(results[0].isError); XCTAssertTrue(results[0].content.contains("mounted http"), results[0].content)
        XCTAssertFalse(results[1].isError, "http was RUNNABLE too, not just listed"); XCTAssertEqual(results[1].content, "fetched https://loopl.dev")

        let changes = events.compactMap { if case .toolsChanged(let m) = $0 { return m }; return nil }
        XCTAssertEqual(changes, [["calculator", "manage_tools"], ["calculator", "http", "manage_tools"]], "toolsChanged: once for the initial set, once for the mount")
        guard case .result(let r)? = events.last else { return XCTFail("no result") }
        XCTAssertEqual(r.text, "done"); XCTAssertEqual(r.metrics.cycleCount, 3)
    }

    func testUnmountMidTurnRemovesFromNextRequestAndCallingItErrors() async throws {
        let registry = ToolRegistry(catalog: [CalculatorTool(), CurrentTimeTool()])
        let model = FakeModel(turns: [
            .toolUse([use(ManageToolsTool.toolName, ["action": "unmount", "names": ["calculator"]], id: "m1")]),
            .toolUse([use("calculator", ["expression": "1+1"], id: "c1")]),
            .text("ok"),
        ])
        let agent = Agent(model: model, tools: [ManageToolsTool(registry: registry)], retryStrategy: nil, registry: registry)
        var results: [ToolResult] = []
        for try await e in agent.stream("x") { if case .toolResult(let r) = e { results.append(r) } }
        let specs = await model.seenToolSpecs.map { $0.map(\.name) }
        XCTAssertEqual(specs[0], ["calculator", "current_time", "manage_tools"])
        XCTAssertEqual(specs[1], ["current_time", "manage_tools"])
        XCTAssertTrue(results[1].isError)
        // The repair path (measured on loopl-0.8b: the model calls the missing tool by name first): a KNOWN, unmounted tool
        // is told exactly how to mount itself, not just "Unknown tool".
        XCTAssertEqual(results[1].content, "calculator exists but is not mounted. Call manage_tools with {\"action\": \"mount\", \"names\": [\"calculator\"]} first, then call calculator again.")
    }

    func testUnknownToolMessagesWithRegistry() async throws {
        let registry = ToolRegistry(catalog: [CalculatorTool(), HttpTool()], mounted: ["calculator"], selfManaging: true)
        await registry.register(ClosureTool(name: "flashlight", description: "torch") { _ in "" }, source: .app, mounted: false, available: false, reason: "No torch on this device.")
        let model = FakeModel(turns: [.toolUse([use("http", id: "a"), use("flashlight", id: "b"), use("teleport", id: "c")]), .text("ok")])
        let agent = Agent(model: model, retryStrategy: nil, registry: registry)
        var results: [ToolResult] = []
        for try await e in agent.stream("x") { if case .toolResult(let r) = e { results.append(r) } }
        let by = Dictionary(uniqueKeysWithValues: results.map { ($0.toolUseId, $0.content) })
        XCTAssertEqual(by["a"], "http exists but is not mounted. Call manage_tools with {\"action\": \"mount\", \"names\": [\"http\"]} first, then call http again.")
        XCTAssertEqual(by["b"], "flashlight cannot run on this device: No torch on this device. Available tools: calculator, manage_tools")
        XCTAssertEqual(by["c"], "Unknown tool: teleport. Available tools: calculator, manage_tools. Tools you can mount with manage_tools: http")
    }

    func testUnknownToolMessageWithoutRegistryIsUnchanged() async throws {
        let model = FakeModel(turns: [.toolUse([use("http", id: "a")]), .text("ok")])
        let agent = Agent(model: model, tools: [CalculatorTool()], retryStrategy: nil)
        var results: [ToolResult] = []
        for try await e in agent.stream("x") { if case .toolResult(let r) = e { results.append(r) } }
        XCTAssertEqual(results.first?.content, "Unknown tool: http. Available tools: calculator")
    }

    func testHostMountBetweenTurnsAndSetToolsMirrorsIntoRegistry() async throws {
        // Settings › Tools toggled between two user messages (the Engine calls registry.setMounted) → next turn sees it.
        let registry = ToolRegistry(catalog: [CalculatorTool(), CurrentTimeTool()], mounted: ["calculator"])
        let model = FakeModel(turns: [.text("a"), .text("b"), .text("c")])
        let agent = Agent(model: model, retryStrategy: nil, registry: registry)
        _ = try await agent("1")
        await registry.setMounted(["current_time"])
        _ = try await agent("2")
        await agent.setTools([CalculatorTool(), CurrentTimeTool()])        // the Engine's per-send setTools keeps working
        _ = try await agent("3")
        let specs = await model.seenToolSpecs.map { $0.map(\.name) }
        XCTAssertEqual(specs, [["calculator"], ["current_time"], ["calculator", "current_time"]])
        let names = await registry.mountedNames
        XCTAssertEqual(names, ["calculator", "current_time"])
    }

    func testAgentWithoutRegistryIsUnchanged() async throws {
        let model = FakeModel(turns: [.text("a")])
        let agent = Agent(model: model, tools: [CalculatorTool()], retryStrategy: nil)
        var changes = 0
        for try await e in agent.stream("x") { if case .toolsChanged = e { changes += 1 } }
        XCTAssertEqual(changes, 0, "no registry → no toolsChanged events, tools exactly as given")
        let r = await agent.registry
        XCTAssertNil(r)
    }

    // MARK: manage_tools results (what the model reads)

    func testListDescribeAndHonestCreate() async throws {
        let registry = ToolRegistry(catalog: [CalculatorTool(), HttpTool()], mounted: ["calculator"])
        await registry.register(ClosureTool(name: "flashlight", description: "torch") { _ in "" }, source: .app, mounted: false, available: false, reason: "No torch on this device.")
        let t = ManageToolsTool(registry: registry)
        let list = try await t.call(["action": "list"])
        XCTAssertTrue(list.hasPrefix("mounted (1): calculator"), list)
        XCTAssertTrue(list.contains("available to mount (1):"), list)
        XCTAssertTrue(list.contains("  http — "), list)
        XCTAssertTrue(list.contains("flashlight — cannot run here: No torch on this device."), list)
        let d = try await t.call(["action": "describe", "name": "http"])
        XCTAssertTrue(d.hasPrefix("http [not mounted]"), d); XCTAssertTrue(d.contains("parameters: {"), d)
        let create = try await t.call(["action": "create", "name": "x", "source": "struct X {}", "language": "swift"])
        XCTAssertTrue(create.contains("not available on this device yet"), create)
        let remove = try await t.call(["action": "remove", "name": "x"])
        XCTAssertTrue(remove.contains("not available on this device yet"), remove)
        do { _ = try await t.call(["action": "mount"]); XCTFail("mount without names must error") } catch let e as ToolError { XCTAssertTrue(e.message.contains("needs names")) }
        do { _ = try await t.call(["action": "fly"]); XCTFail() } catch let e as ToolError { XCTAssertTrue(e.message.contains("unknown action")) }
    }

    func testNamesAsSmallModelsSendThem() {
        // Measured on loopl-0.8b: "calculator", "[remember]", "http, calculator" instead of a JSON array.
        XCTAssertEqual(ManageToolsTool.names(from: .array(["http", "calculator"])), ["http", "calculator"])
        XCTAssertEqual(ManageToolsTool.names(from: .string("calculator")), ["calculator"])
        XCTAssertEqual(ManageToolsTool.names(from: .string("[remember]")), ["remember"])
        XCTAssertEqual(ManageToolsTool.names(from: .string("http, calculator http")), ["http", "calculator"])
        XCTAssertEqual(ManageToolsTool.names(from: .string("[\"http\", \"recall\"]")), ["http", "recall"])
        XCTAssertEqual(ManageToolsTool.names(from: nil), [])
    }

    func testMountOnCallMountsAndRunsAKnownUnmountedTool() async throws {
        let registry = ToolRegistry(catalog: [CalculatorTool(), CurrentTimeTool()], mounted: ["current_time"], selfManaging: true)
        await registry.setMountOnCall(true)
        let model = FakeModel(turns: [.toolUse([use("calculator", ["expression": "2*3"], id: "c")]), .text("6")])
        let agent = Agent(model: model, retryStrategy: nil, registry: registry)
        var results: [ToolResult] = []; var changes: [[String]] = []
        for try await e in agent.stream("x") {
            if case .toolResult(let r) = e { results.append(r) }
            if case .toolsChanged(let m) = e { changes.append(m) }
        }
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].content, "(calculator was not mounted — mounted it for this conversation.)\n2*3 = 6")
        XCTAssertEqual(changes.last, ["calculator", "current_time", "manage_tools"])
        let specs = await model.seenToolSpecs.map { $0.map(\.name) }
        XCTAssertEqual(specs[1], ["calculator", "current_time", "manage_tools"], "the next request offers it too")
        // Off (default): the same call is the repair hint, not a run.
        let r2 = ToolRegistry(catalog: [CalculatorTool()], mounted: [], selfManaging: true)
        let m2 = FakeModel(turns: [.toolUse([use("calculator", ["expression": "2*3"], id: "c")]), .text("ok")])
        let a2 = Agent(model: m2, retryStrategy: nil, registry: r2)
        var r2results: [ToolResult] = []
        for try await e in a2.stream("x") { if case .toolResult(let r) = e { r2results.append(r) } }
        XCTAssertTrue(r2results[0].isError); XCTAssertTrue(r2results[0].content.contains("exists but is not mounted"))
    }

    func testCreateThroughAPluggedCreator() async throws {
        struct Creator: ToolCreator {
            var languages: [String] { ["javascript"] }
            func create(name: String, source: String, language: String) async throws -> any Tool {
                guard source.contains("return") else { throw ToolError("no return statement") }
                return ClosureTool(name: name, description: "created \(language)") { _ in "hi from \(name)" }
            }
            func remove(name: String) async throws {}
            func saved() async -> [(name: String, language: String)] { [] }
        }
        let registry = ToolRegistry(catalog: [CalculatorTool()])
        await registry.setCreator(Creator())
        let t = ManageToolsTool(registry: registry)
        do { _ = try await t.call(["action": "create", "name": "greet", "source": "x", "language": "swift"]); XCTFail() }
        catch let e as ToolError { XCTAssertTrue(e.message.contains("write javascript instead"), e.message) }
        do { _ = try await t.call(["action": "create", "name": "greet", "source": "x"]); XCTFail() }
        catch let e as ToolError { XCTAssertEqual(e.message, "no return statement") }
        let ok = try await t.call(["action": "create", "name": "greet", "source": "return 1"])
        XCTAssertTrue(ok.hasPrefix("created and mounted \"greet\" (javascript)"), ok)
        let names = await registry.mountedNames
        XCTAssertEqual(names, ["calculator", "greet"])
        let out = try await registry.tool(named: "greet")!.call([:])
        XCTAssertEqual(out, "hi from greet")
        do { _ = try await t.call(["action": "remove", "name": "calculator"]); XCTFail() }
        catch let e as ToolError { XCTAssertTrue(e.message.contains("built in"), e.message) }
        let removed = try await t.call(["action": "remove", "name": "greet"])
        XCTAssertEqual(removed, "removed \"greet\".")
        let after = await registry.names
        XCTAssertEqual(after, ["calculator"])
    }
}
