import XCTest
@testable import Loopl

/// Phase 7 CONTROLS: `ToolOutput.control` → `ToolResult.control` (UI-only, Codable, tolerant), `Agent.invokeTool` (a tap
/// runs ONE tool through the normal path — approval included — with no model call, and the model's history learns it), and
/// `Transcript.applyControlResult` (the tapped row updates in place; no new row).
final class ToolControlTests: XCTestCase {
    /// A "flashlight": `on` → control "Turn off"; `off` → "Turn on". Records calls. Asks for approval when `guarded`.
    final class Torch: Tool, @unchecked Sendable {
        let name = "flashlight"; let description = "x"
        let parameters: JSONValue = ToolSchema.object(["state": ToolSchema.string("on|off")], required: ["state"])
        let guarded: Bool
        private let lock = NSLock(); private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        init(guarded: Bool = false) { self.guarded = guarded }
        func call(_ args: [String: JSONValue]) async throws -> String { try await callOutput(args).text }
        func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
            let on = args["state"]?.stringValue == "on"
            lock.withLock { _calls.append(on ? "on" : "off") }
            return ToolOutput(text: on ? "flashlight: on" : "flashlight: off",
                              control: .toggle(label: on ? "Turn off" : "Turn on", on: on,
                                               action: ControlAction(tool: "flashlight", args: ["state": .string(on ? "off" : "on")])))
        }
        func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
        func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
            guarded ? ApprovalRequest(toolName: name, title: "Flashlight", method: "SET", url: nil, bodyPreview: nil, detail: nil, risk: .medium, input: input) : nil
        }
    }

    func testControlRoundTripsThroughJSONAndTheDefaultIsNone() throws {
        let controls: [ToolControl] = [
            .toggle(label: "Turn off", on: true, action: ControlAction(tool: "flashlight", args: ["state": .string("off"), "level": .number(0.5)])),
            .button(label: "Vibrate again", action: ControlAction(tool: "vibrate", args: ["pattern": .string("double")])),
            .player(.init(title: "So What", subtitle: "Miles Davis", playing: true, volume: 40)),
            .mapPin(lat: 40.74, lon: -74.03, label: "Hoboken"),
            .timer(until: Date(timeIntervalSince1970: 1_800_000_000), label: "Tea"),
            .link(label: "Open in Calendar", url: "calshow:800000000"),
        ]
        for c in controls {
            let data = try JSONEncoder().encode(c)
            let back = try JSONDecoder().decode(ToolControl.self, from: data)
            XCTAssertEqual(back, c, c.typeName)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(obj?["type"] as? String, c.typeName, "a flat `type` discriminator the dataset can read")
        }
        // A result without a control (every pre-Phase-7 file) decodes as nil; an unknown control type is dropped, not fatal.
        let r = ToolResult(toolUseId: "t", name: "calculator", content: "2")
        let plain = try JSONDecoder().decode(ToolResult.self, from: try JSONEncoder().encode(r))
        XCTAssertNil(plain.control)
        let future = #"{"toolUseId":"t","name":"x","status":"success","content":"c","durationMs":1,"control":{"type":"hologram"}}"#
        let tolerant = try JSONDecoder().decode(ToolResult.self, from: Data(future.utf8))
        XCTAssertNil(tolerant.control); XCTAssertEqual(tolerant.content, "c")
        // The control never reaches the model's text.
        var withControl = r; withControl.control = controls[0]
        XCTAssertFalse(withControl.promptContent.contains("Turn off"))
    }

    func testToolOutputControlLandsOnTheResultThroughTheAgent() async throws {
        let model = FakeModel(turns: [.toolUse([ToolUse(toolUseId: "f1", name: "flashlight", input: ["state": .string("on")])]), .text("on")])
        let tool = Torch()
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        var results: [ToolResult] = []
        for try await ev in agent.stream("light") { if case .toolResult(let r) = ev { results.append(r) } }
        XCTAssertEqual(results.count, 1)
        guard case .toggle(let label, let on, let action)? = results[0].control else { return XCTFail("control missing on the result") }
        XCTAssertEqual(label, "Turn off"); XCTAssertTrue(on); XCTAssertEqual(action.args["state"], .string("off"))
    }

    func testInvokeToolRunsWithoutAModelCallAndTheHistoryLearnsIt() async throws {
        let model = FakeModel(turns: [.toolUse([ToolUse(toolUseId: "f1", name: "flashlight", input: ["state": .string("on")])]), .text("on")])
        let tool = Torch()
        let agent = Agent(model: model, tools: [tool], retryStrategy: nil)
        for try await _ in agent.stream("light") {}
        let before = await agent.messages.count
        let callsBefore = await model.seenPrompts.count
        // The tap: the control's own action, through the agent, no model turn.
        let tap = ToolUse(toolUseId: "tap_1", name: "flashlight", input: ["state": .string("off")])
        var events: [AgentEvent] = []
        for try await ev in agent.invokeTool(tap) { events.append(ev) }
        let callsAfter = await model.seenPrompts.count
        XCTAssertEqual(callsAfter, callsBefore, "a tap is not a model turn")
        XCTAssertEqual(tool.calls, ["on", "off"])
        let started = events.compactMap { if case .toolStarted(let u) = $0 { return u.toolUseId }; return nil }
        XCTAssertEqual(started, ["tap_1"])
        guard case .toolResult(let r)? = events.last else { return XCTFail("last event must be the result, got \(events)") }
        XCTAssertEqual(r.content, "flashlight: off")
        guard case .toggle(let label, let on, _)? = r.control else { return XCTFail("fresh control") }
        XCTAssertEqual(label, "Turn on"); XCTAssertFalse(on)
        XCTAssertFalse(events.contains { if case .result = $0 { return true }; return false }, "no AgentResult: nothing ended a turn")
        // The model's history: one assistant tool-use + one tool-result pair, the result marked as the user's tap.
        let msgs = await agent.messages
        XCTAssertEqual(msgs.count, before + 2)
        XCTAssertEqual(msgs[before].role, .assistant); XCTAssertEqual(msgs[before].toolUses.map(\.toolUseId), ["tap_1"])
        let fed = msgs[before + 1].toolResults.first
        XCTAssertEqual(fed?.toolUseId, "tap_1")
        XCTAssertTrue(fed?.content.hasPrefix(Agent.tappedResultPrefix) == true, "the model is told the USER did it: \(fed?.content ?? "")")
        XCTAssertNil(fed?.control, "the control is UI-only, never in the model's messages")
    }

    func testInvokeToolGoesThroughTheApprovalPolicy() async throws {
        let model = FakeModel(turns: [.text("hi")])
        let tool = Torch(guarded: true)
        let agent = Agent(model: model, tools: [tool], hooks: [ApprovalPolicy(mode: .always)], retryStrategy: nil)
        for try await _ in agent.stream("hi") {}
        let tap = ToolUse(toolUseId: "tap_2", name: "flashlight", input: ["state": .string("off")])
        var asked: [ApprovalRequest] = []
        var result: ToolResult?
        for try await ev in agent.invokeTool(tap) {
            switch ev {
            case .approvalRequested(let req):
                asked.append(req)
                Task { _ = await agent.resolve(approval: req.id, .deny(reason: "not now")) }
            case .toolResult(let r): result = r
            default: break
            }
        }
        XCTAssertEqual(asked.map(\.id), ["tap_2"], "the tap asks exactly like a model's call would")
        XCTAssertEqual(tool.calls, [], "denied → the torch never ran")
        XCTAssertEqual(result?.isError, true)
    }

    func testInvokeToolUnknownToolIsAnHonestError() async throws {
        let agent = Agent(model: FakeModel(turns: [.text("hi")]), tools: [Torch()], retryStrategy: nil)
        var result: ToolResult?
        for try await ev in agent.invokeTool(ToolUse(toolUseId: "tap_3", name: "nope", input: [:])) { if case .toolResult(let r) = ev { result = r } }
        XCTAssertEqual(result?.isError, true)
        XCTAssertTrue(result?.content.contains("Unknown tool") == true)
    }

    func testTranscriptAppliesAControlResultInPlace() {
        var t = Transcript()
        t.user("light")
        let use = ToolUse(toolUseId: "f1", name: "flashlight", input: ["state": .string("on")])
        t.apply(.toolStarted(use))
        t.apply(.toolResult(ToolResult(toolUseId: "f1", name: "flashlight", content: "flashlight: on",
                                       control: .toggle(label: "Turn off", on: true, action: ControlAction(tool: "flashlight", args: ["state": .string("off")])))))
        let rows = t.items.count
        let fresh = ToolResult(toolUseId: "tap_9", name: "flashlight", content: "flashlight: off",
                               control: .toggle(label: "Turn on", on: false, action: ControlAction(tool: "flashlight", args: ["state": .string("on")])))
        XCTAssertTrue(t.applyControlResult(for: "f1", fresh))
        XCTAssertEqual(t.items.count, rows, "no new row: the tapped row IS the row")
        guard case .toolUse(let u, let r?) = t.items[1].kind else { return XCTFail("row") }
        XCTAssertEqual(u.input["state"], .string("on"), "the row keeps its original arguments")
        XCTAssertEqual(r.toolUseId, "f1", "the result is re-keyed to the row")
        XCTAssertEqual(r.content, "flashlight: off")
        XCTAssertEqual(t.items[1].controlTaps, 1)
        XCTAssertFalse(t.applyControlResult(for: "gone", fresh))
    }
}
